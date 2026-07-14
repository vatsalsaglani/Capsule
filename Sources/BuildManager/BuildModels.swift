import ContainerClient
import Foundation

public struct BuildID: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct BuildRequest: Sendable, Hashable {
    public var contextDirectory: URL
    public var dockerfile: URL?
    public var tags: [String]
    public var arguments: [String: String]
    public var target: String?
    public var platform: String?
    public var labels: [String: String]
    public var cachePolicy: BuildCachePolicy
    public var baseImagePolicy: BaseImagePolicy

    public init(
        contextDirectory: URL,
        dockerfile: URL? = nil,
        tags: [String],
        arguments: [String: String] = [:],
        target: String? = nil,
        platform: String? = nil,
        labels: [String: String] = [:],
        cachePolicy: BuildCachePolicy = .useCache,
        baseImagePolicy: BaseImagePolicy = .useLocal
    ) {
        self.contextDirectory = contextDirectory
        self.dockerfile = dockerfile
        self.tags = tags
        self.arguments = arguments
        self.target = target
        self.platform = platform
        self.labels = labels
        self.cachePolicy = cachePolicy
        self.baseImagePolicy = baseImagePolicy
    }
}

/// Frontends can pass raw form/flag text without owning parsing or
/// validation policy. Resolution remains independently unit-testable here.
public struct BuildFormInput: Sendable, Hashable {
    public var contextDirectory: URL
    public var dockerfile: URL?
    public var tags: String
    public var arguments: String
    public var target: String
    public var platform: String
    public var noCache: Bool
    public var pullBaseImages: Bool

    public init(
        contextDirectory: URL,
        dockerfile: URL? = nil,
        tags: String,
        arguments: String = "",
        target: String = "",
        platform: String = "",
        noCache: Bool = false,
        pullBaseImages: Bool = false
    ) {
        self.contextDirectory = contextDirectory
        self.dockerfile = dockerfile
        self.tags = tags
        self.arguments = arguments
        self.target = target
        self.platform = platform
        self.noCache = noCache
        self.pullBaseImages = pullBaseImages
    }

    public func request() throws -> BuildRequest {
        BuildRequest(
            contextDirectory: contextDirectory,
            dockerfile: dockerfile,
            tags: tags
                .split(whereSeparator: { $0 == "," || $0.isNewline })
                .map(String.init),
            arguments: try BuildArgumentInputParser.parse(
                arguments.split(whereSeparator: \.isNewline).map(String.init)
            ),
            target: target,
            platform: platform,
            cachePolicy: noCache ? .noCache : .useCache,
            baseImagePolicy: pullBaseImages ? .pull : .useLocal
        )
    }
}

public struct ResolvedBuildRequest: Sendable, Hashable {
    public let spec: ImageBuildSpec
    public let tags: [String]
    public let argumentKeys: [String]
}

public enum BuildRequestError: Error, Sendable, Equatable {
    case contextNotDirectory(String)
    case dockerfileNotFound(String)
    case noDockerfile(String)
    case missingTag
    case invalidBuildArgument(String)
}

extension BuildRequestError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .contextNotDirectory(let path): "Build context is not a directory: \(path)"
        case .dockerfileNotFound(let path): "Dockerfile was not found: \(path)"
        case .noDockerfile(let path): "No Dockerfile was found in \(path)."
        case .missingTag: "At least one image tag is required."
        case .invalidBuildArgument(let value): "Build argument must use KEY=VALUE syntax: \(value)"
        }
    }
}

public enum BuildArgumentInputParser {
    public static func parse(_ values: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for value in values {
            guard let separator = value.firstIndex(of: "=") else {
                throw BuildRequestError.invalidBuildArgument(value)
            }
            let key = String(value[..<separator]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { throw BuildRequestError.invalidBuildArgument(value) }
            let next = value.index(after: separator)
            result[key] = String(value[next...])
        }
        return result
    }
}

public enum BuildRequestResolver {
    public static func resolve(
        _ request: BuildRequest,
        fileManager: FileManager = .default
    ) throws -> ResolvedBuildRequest {
        let context = request.contextDirectory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: context.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BuildRequestError.contextNotDirectory(context.path)
        }

        let dockerfile: URL
        if let requested = request.dockerfile?.standardizedFileURL {
            guard fileManager.fileExists(atPath: requested.path) else {
                throw BuildRequestError.dockerfileNotFound(requested.path)
            }
            dockerfile = requested
        } else {
            let candidates = ["Dockerfile", "dockerfile"].map { context.appending(path: $0) }
            guard let detected = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
                throw BuildRequestError.noDockerfile(context.path)
            }
            dockerfile = detected
        }

        var seen = Set<String>()
        let tags = request.tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard let primary = tags.first else { throw BuildRequestError.missingTag }

        return ResolvedBuildRequest(
            spec: ImageBuildSpec(
                contextDirectory: context,
                dockerfile: dockerfile,
                tag: primary,
                arguments: request.arguments,
                target: request.target?.nilIfBlank,
                platform: request.platform?.nilIfBlank,
                labels: request.labels,
                cachePolicy: request.cachePolicy,
                baseImagePolicy: request.baseImagePolicy
            ),
            tags: tags,
            argumentKeys: request.arguments.keys.sorted()
        )
    }
}

public enum BuildState: String, Sendable, Hashable, Codable {
    case running
    case succeeded
    case cancelled
    case failed
}

/// Persisted history deliberately stores build-argument keys, never values:
/// CI and local builds commonly pass credentials through `--build-arg`.
public struct BuildRequestSummary: Sendable, Hashable, Codable {
    public let contextPath: String
    public let dockerfilePath: String
    public let tags: [String]
    public let argumentKeys: [String]
    public let target: String?
    public let platform: String?
    public let cachePolicy: BuildCachePolicy
    public let baseImagePolicy: BaseImagePolicy

    public init(
        contextPath: String,
        dockerfilePath: String,
        tags: [String],
        argumentKeys: [String],
        target: String?,
        platform: String?,
        cachePolicy: BuildCachePolicy,
        baseImagePolicy: BaseImagePolicy
    ) {
        self.contextPath = contextPath
        self.dockerfilePath = dockerfilePath
        self.tags = tags
        self.argumentKeys = argumentKeys
        self.target = target
        self.platform = platform
        self.cachePolicy = cachePolicy
        self.baseImagePolicy = baseImagePolicy
    }
}

public struct BuildRecord: Sendable, Hashable, Codable, Identifiable {
    public let id: BuildID
    public let request: BuildRequestSummary
    public var state: BuildState
    public let startedAt: Date
    public var finishedAt: Date?
    public var output: [BuildProgress]
    public var failureMessage: String?

    public init(
        id: BuildID,
        request: BuildRequestSummary,
        state: BuildState = .running,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        output: [BuildProgress] = [],
        failureMessage: String? = nil
    ) {
        self.id = id
        self.request = request
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.output = output
        self.failureMessage = failureMessage
    }
}

public enum BuildEvent: Sendable {
    case started(BuildRecord)
    case progress(BuildProgress)
    case tagging(String)
    case finished(BuildRecord)
}

public struct BuildExecution: Sendable {
    public let id: BuildID
    public let events: AsyncStream<BuildEvent>

    public init(id: BuildID, events: AsyncStream<BuildEvent>) {
        self.id = id
        self.events = events
    }
}

public enum BuildCenterError: Error, Sendable {
    case activeBuilds
    case builderBusy
}

extension BuildCenterError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .activeBuilds: "Stop the active build before changing the builder lifecycle."
        case .builderBusy: "Wait for the current builder lifecycle operation to finish."
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
