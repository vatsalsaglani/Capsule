import Foundation

/// The raw response returned by an image-icon HTTP client. Keeping the
/// transport response value-only makes the cache testable without a live
/// registry or `URLProtocol` interception.
public struct ImageIconHTTPResponse: Sendable, Equatable {
    public let data: Data
    public let statusCode: Int
    public let contentType: String?

    public init(data: Data, statusCode: Int, contentType: String?) {
        self.data = data
        self.statusCode = statusCode
        self.contentType = contentType
    }
}

/// The small transport boundary needed by ``ImageIconCache``. It is purposefully
/// separate from `ContainerRuntime`: registry logos are optional presentation
/// metadata, not part of Apple's container runtime contract.
public protocol ImageIconHTTPClient: Sendable {
    func fetch(_ url: URL) async throws -> ImageIconHTTPResponse
}

/// Production HTTPS implementation for the optional logo lookup.
public struct URLSessionImageIconHTTPClient: ImageIconHTTPClient {
    public init() {}

    public func fetch(_ url: URL) async throws -> ImageIconHTTPResponse {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Capsule image-icon resolver", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ImageIconHTTPError.nonHTTPResponse
        }
        return ImageIconHTTPResponse(
            data: data,
            statusCode: response.statusCode,
            contentType: response.mimeType
        )
    }
}

public enum ImageIconHTTPError: Error, Sendable {
    case nonHTTPResponse
}

/// Resolves and persists small logos for public Docker Official Images.
///
/// Registry/OCI metadata has no portable icon field. Instead, this intentionally
/// narrow provider reads only Docker's public Official Images documentation
/// source for `docker.io/library/*` references. Private, custom-registry, and
/// unsupported image references never produce an outbound request and therefore
/// retain Capsule's local fallback glyph.
public actor ImageIconCache {
    private enum CacheLookup {
        case image(Data)
        case missing
        case none
    }

    private struct InFlight {
        let token: UUID
        let task: Task<Data?, Never>
    }

    private static let negativeCacheLifetime: TimeInterval = 24 * 60 * 60
    private static let maximumLogoBytes = 512 * 1_024
    private static let pngSignature = Data([137, 80, 78, 71, 13, 10, 26, 10])
    private static let officialDocsRoot = URL(string: "https://raw.githubusercontent.com/docker-library/docs/master/")!

    private let cacheDirectory: URL
    private let httpClient: any ImageIconHTTPClient
    private let now: @Sendable () -> Date
    private var inFlight: [String: InFlight] = [:]

    public init(
        cacheDirectory: URL? = nil,
        httpClient: any ImageIconHTTPClient = URLSessionImageIconHTTPClient(),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory
        self.httpClient = httpClient
        self.now = now
    }

    deinit {
        for entry in inFlight.values {
            entry.task.cancel()
        }
    }

    /// Returns an icon only when `imageReference` identifies a public Docker
    /// Official Image with a valid cached or remotely available PNG logo.
    /// Network failures deliberately remain invisible: the UI simply keeps the
    /// local fallback and retries on a later visit rather than presenting an
    /// unrelated registry error on the Images screen.
    public func data(for imageReference: String) async -> Data? {
        guard let repository = Self.officialRepository(for: imageReference) else {
            return nil
        }

        switch cachedData(for: repository) {
        case .image(let data):
            return data
        case .missing:
            return nil
        case .none:
            break
        }

        if let existing = inFlight[repository.cacheKey] {
            return await existing.task.value
        }

        let token = UUID()
        let task = Task<Data?, Never> { [cacheDirectory, httpClient, now] in
            await Self.fetchAndCache(
                repository: repository,
                cacheDirectory: cacheDirectory,
                httpClient: httpClient,
                now: now
            )
        }
        inFlight[repository.cacheKey] = InFlight(token: token, task: task)

        let data = await task.value
        if inFlight[repository.cacheKey]?.token == token {
            inFlight[repository.cacheKey] = nil
        }
        return data
    }

    /// Exposes the supported-source decision for tests and future UI copy
    /// without widening the actual image-logo retrieval API.
    public nonisolated static func officialLogoURL(for imageReference: String) -> URL? {
        guard let repository = officialRepository(for: imageReference) else { return nil }
        return officialDocsRoot
            .appending(path: repository.name, directoryHint: .isDirectory)
            .appending(path: "logo.png")
    }

    private nonisolated static var defaultCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Capsule", directoryHint: .isDirectory)
            .appending(path: "ImageIcons-v1", directoryHint: .isDirectory)
    }

    private func cachedData(for repository: OfficialRepository) -> CacheLookup {
        let imageURL = cacheURL(for: repository, extension: "png")
        if let data = try? Data(contentsOf: imageURL) {
            if Self.isValidPNG(data) {
                return .image(data)
            }
            try? FileManager.default.removeItem(at: imageURL)
        }

        let missingURL = cacheURL(for: repository, extension: "missing")
        if let string = try? String(contentsOf: missingURL, encoding: .utf8),
           let timestamp = TimeInterval(string.trimmingCharacters(in: .whitespacesAndNewlines)),
           now().timeIntervalSince1970 - timestamp < Self.negativeCacheLifetime {
            return .missing
        }
        try? FileManager.default.removeItem(at: missingURL)
        return .none
    }

    private func cacheURL(for repository: OfficialRepository, extension fileExtension: String) -> URL {
        cacheDirectory.appending(path: "\(repository.cacheKey).\(fileExtension)")
    }

    private nonisolated static func fetchAndCache(
        repository: OfficialRepository,
        cacheDirectory: URL,
        httpClient: any ImageIconHTTPClient,
        now: @escaping @Sendable () -> Date
    ) async -> Data? {
        guard let logoURL = officialLogoURL(for: repository.reference) else { return nil }

        do {
            try Task.checkCancellation()
            let response = try await httpClient.fetch(logoURL)
            try Task.checkCancellation()

            if response.statusCode == 200, isValidPNG(response.data, contentType: response.contentType) {
                try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                let imageURL = cacheDirectory.appending(path: "\(repository.cacheKey).png")
                try? response.data.write(to: imageURL, options: .atomic)
                try? FileManager.default.removeItem(at: cacheDirectory.appending(path: "\(repository.cacheKey).missing"))
                return response.data
            }

            if (400...499).contains(response.statusCode) || response.statusCode == 200 {
                try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                let missingURL = cacheDirectory.appending(path: "\(repository.cacheKey).missing")
                let timestamp = String(now().timeIntervalSince1970)
                try? timestamp.write(to: missingURL, atomically: true, encoding: .utf8)
            }
        } catch is CancellationError {
            return nil
        } catch {
            // A transport outage is not a permanent “not found”; retain the
            // fallback now and allow a later screen visit to try again.
            return nil
        }
        return nil
    }

    private nonisolated static func isValidPNG(_ data: Data, contentType: String? = nil) -> Bool {
        guard data.count <= maximumLogoBytes, data.starts(with: pngSignature) else { return false }
        guard let contentType else { return true }
        return contentType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "image/png"
    }

    private nonisolated static func officialRepository(for imageReference: String) -> OfficialRepository? {
        let withoutDigest = imageReference.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
        var components = withoutDigest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, !components.contains(where: \.isEmpty) else { return nil }

        var name = components.removeLast()
        if let tagSeparator = name.lastIndex(of: ":") {
            name = String(name[..<tagSeparator])
        }
        guard !name.isEmpty else { return nil }

        let registry: String
        let namespace: String
        if let first = components.first, isRegistryComponent(first) {
            registry = normalizedRegistry(first)
            components.removeFirst()
            namespace = components.joined(separator: "/").lowercased()
        } else {
            registry = "docker.io"
            namespace = components.isEmpty ? "library" : components.joined(separator: "/").lowercased()
        }

        let normalizedName = name.lowercased()
        guard registry == "docker.io", namespace == "library", isSafeRepositoryName(normalizedName) else {
            return nil
        }
        return OfficialRepository(name: normalizedName)
    }

    private nonisolated static func isRegistryComponent(_ component: String) -> Bool {
        component.contains(".") || component.contains(":") || component == "localhost"
    }

    private nonisolated static func normalizedRegistry(_ registry: String) -> String {
        switch registry.lowercased() {
        case "index.docker.io", "registry-1.docker.io": "docker.io"
        default: registry.lowercased()
        }
    }

    private nonisolated static func isSafeRepositoryName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { character in
            character.isLetter || character.isNumber || character == "." || character == "_" || character == "-"
        }
    }
}

private struct OfficialRepository: Sendable {
    let name: String

    var reference: String { "docker.io/library/\(name)" }
    var cacheKey: String { "docker.io__library__\(name)" }
}
