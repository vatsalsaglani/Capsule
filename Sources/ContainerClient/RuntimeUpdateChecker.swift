import Foundation

/// Watches apple/container GitHub releases so Capsule can offer runtime
/// install/update guidance (onboarding + doctor). Capsule never installs the
/// .pkg silently — it downloads/links and lets the user run the installer.
public struct GitHubRelease: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let browserDownloadURL: URL

        private enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    public let tagName: String
    public let htmlURL: URL
    public let assets: [Asset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }

    public var version: SemanticVersion? { SemanticVersion(firstIn: tagName) }

    /// The signed installer package, if this release ships one.
    public var installerPackage: Asset? {
        assets.first { $0.name.hasSuffix(".pkg") }
    }
}

public struct RuntimeUpdateChecker: Sendable {
    public let repository: String

    public init(repository: String = "apple/container") {
        self.repository = repository
    }

    public func latestRelease() async throws -> GitHubRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    /// Returns the newer release, or nil when `installed` is current.
    public func updateAvailable(installed: SemanticVersion) async throws -> GitHubRelease? {
        let latest = try await latestRelease()
        guard let latestVersion = latest.version, latestVersion > installed else { return nil }
        return latest
    }
}
