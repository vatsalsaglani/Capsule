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

        public init(name: String, browserDownloadURL: URL) {
            self.name = name
            self.browserDownloadURL = browserDownloadURL
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

    /// Test/fixture construction — `Decodable` already covers the real
    /// GitHub API response; this lets `RuntimeInstallerTests` build fixtures
    /// without a live network call (verified live against
    /// `api.github.com/repos/apple/container/releases/latest` for P1D: tag
    /// `1.1.0`, assets `container-1.1.0-installer-signed.pkg`,
    /// `container-installer-unsigned.pkg`, `container-dSYM.zip` — see
    /// `docs/learnings/2026-07-13-runtime-installer-release-assets.md`).
    public init(tagName: String, htmlURL: URL, assets: [Asset] = []) {
        self.tagName = tagName
        self.htmlURL = htmlURL
        self.assets = assets
    }

    public var version: SemanticVersion? { SemanticVersion(firstIn: tagName) }

    /// The installer package to hand off to the user, if this release ships
    /// one. apple/container releases have shipped *two* `.pkg` assets at once
    /// (a signed one and an `-unsigned` one, see the learnings note above) —
    /// prefer the signed package explicitly rather than trusting asset
    /// order, since Capsule is guiding the user to actually run this
    /// installer (rule 7, AGENTS.md).
    public var installerPackage: Asset? {
        assets.first { $0.name.hasSuffix(".pkg") && !$0.name.contains("unsigned") }
            ?? assets.first { $0.name.hasSuffix(".pkg") }
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

/// Pure result of comparing an installed version against a GitHub release
/// tag — no network, so it's directly unit-testable. `RuntimeInstaller`
/// drives its onboarding/update-banner state off this.
public enum RuntimeUpdateStatus: Sendable, Equatable {
    case upToDate(current: SemanticVersion)
    case updateAvailable(current: SemanticVersion, latest: SemanticVersion)
    /// The release tag didn't parse as `x.y.z` — surfaced honestly rather
    /// than guessed at (rule 10, AGENTS.md).
    case unknown
}

extension RuntimeUpdateChecker {
    /// Pure comparison — no network. Uses `SemanticVersion` ordering, so a
    /// major bump (e.g. installed 1.x, latest tag `2.0.0`) still reports
    /// `.updateAvailable`, never silently swallowed (rule 10: Capsule targets
    /// `container` 1.x today, but a 2.x release is real news for the user,
    /// not something to hide).
    public func evaluate(installed: SemanticVersion, latestTag: String) -> RuntimeUpdateStatus {
        guard let latest = SemanticVersion(firstIn: latestTag) else { return .unknown }
        guard latest > installed else { return .upToDate(current: installed) }
        return .updateAvailable(current: installed, latest: latest)
    }
}
