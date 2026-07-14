import ContainerClient
import Foundation
import Observation

/// Whether the `container` binary is currently reachable — mirrors
/// `ContainerBinaryLocator`/`RuntimeError.binaryNotFound`'s vocabulary rather
/// than inventing a new one.
public enum RuntimePresence: Sendable, Equatable {
    /// Haven't checked yet (initial state, before the first `refresh()`).
    case unknown
    case present(version: SemanticVersion)
    case missing(searchedPaths: [String])
}

/// State machine for `prepareInstaller()`. Every terminal state is honest
/// about what happened — Capsule never silently installs (rule 7, AGENTS.md):
/// the model's job stops at "here is a file, go run it yourself."
public enum RuntimeInstallDownloadPhase: Sendable, Equatable {
    case idle
    case resolving
    case downloading(fraction: Double?)
    /// `localURL` is a **file URL** when a `.pkg` was actually downloaded
    /// (`localURL.isFileURL == true`); when no `.pkg` asset exists on the
    /// release, this instead carries the release's `htmlURL` (a web URL) as
    /// a fallback destination — callers must branch on `isFileURL` before
    /// deciding whether to reveal-in-Finder vs. open-in-browser.
    case ready(localURL: URL, humanInstructions: String)
    case failed(message: String)
}

/// Mirrors the `AppCore` composition-root store shape (`RuntimeSession` et
/// al.): `@MainActor @Observable`, plain Foundation/Observation/ContainerClient
/// imports, no SwiftUI — `App/Capsule/Onboarding/` is the thin frontend over
/// this (rule 1, AGENTS.md).
///
/// **Rule 7 is absolute here:** this model downloads/resolves an installer
/// and reports where it landed. It never invokes `installer`, never shells
/// `open -a Installer`, never asks for `sudo` — there is no such API on this
/// type. The onboarding UI's only next step is to reveal the file (Finder)
/// or open the release page and let the user do it.
@MainActor
@Observable
public final class RuntimeInstallerModel {
    public private(set) var runtimePresence: RuntimePresence = .unknown
    public private(set) var updateStatus: RuntimeUpdateStatus?
    public private(set) var downloadPhase: RuntimeInstallDownloadPhase = .idle

    /// Builds the base runtime freshly on every `refresh()` call (never
    /// cached) — mirrors `RuntimeSession`'s `makeRuntime` seam. Freshness
    /// matters here specifically: after the user runs a downloaded installer
    /// outside Capsule, "re-check on activation" (P1D spec) must re-locate
    /// the binary from scratch rather than replay a stale construction
    /// failure.
    private let runtimeFactory: () throws -> any ContainerRuntime
    private let fetchLatestRelease: () async throws -> GitHubRelease
    private let download: (URL) async throws -> URL
    private let checker: RuntimeUpdateChecker

    /// Test/advanced injection point — no network or filesystem access from
    /// unit tests. Production wires the real `CLIProcessClient`,
    /// `RuntimeUpdateChecker.latestRelease()`, and a URLSession download (see
    /// the `repository:` convenience initializer).
    public init(
        runtimeFactory: @escaping () throws -> any ContainerRuntime,
        fetchLatestRelease: @escaping () async throws -> GitHubRelease,
        download: @escaping (URL) async throws -> URL,
        checker: RuntimeUpdateChecker = RuntimeUpdateChecker()
    ) {
        self.runtimeFactory = runtimeFactory
        self.fetchLatestRelease = fetchLatestRelease
        self.download = download
        self.checker = checker
    }

    /// Production wiring: real `CLIProcessClient` auto-locate, real
    /// `apple/container` GitHub releases, a URLSession download task to a
    /// scratch temp directory (never `~/Downloads` without asking, never a
    /// privileged location).
    public convenience init(repository: String = "apple/container") {
        let checker = RuntimeUpdateChecker(repository: repository)
        self.init(
            runtimeFactory: { try CLIProcessClient() },
            fetchLatestRelease: { try await checker.latestRelease() },
            download: { url in try await Self.downloadToTemporaryFile(from: url) },
            checker: checker
        )
    }

    /// Determines `runtimePresence` (constructing the runtime fresh, never
    /// reusing a prior instance — see `runtimeFactory`'s doc comment) and,
    /// when present, the update status against the latest GitHub release. A
    /// network failure during the update check degrades to `updateStatus =
    /// nil` rather than throwing — presence is still truthful even if the
    /// update check couldn't run.
    public func refresh() async {
        let runtime: any ContainerRuntime
        do {
            runtime = try runtimeFactory()
        } catch {
            runtimePresence = .missing(searchedPaths: Self.searchedPaths(for: error))
            updateStatus = nil
            return
        }

        do {
            let version = try await runtime.cliVersion()
            runtimePresence = .present(version: version)
            do {
                let release = try await fetchLatestRelease()
                updateStatus = checker.evaluate(installed: version, latestTag: release.tagName)
            } catch {
                updateStatus = nil
            }
        } catch {
            runtimePresence = .missing(searchedPaths: Self.searchedPaths(for: error))
            updateStatus = nil
        }
    }

    /// Resolves the latest release, downloads its `.pkg` (if one is
    /// attached), and reports where it landed. **Never executes anything** —
    /// see the type's doc comment. Failure at any step (network, no release,
    /// download I/O) lands in `.failed(message:)` with the real error text.
    public func prepareInstaller() async {
        downloadPhase = .resolving
        let release: GitHubRelease
        do {
            release = try await fetchLatestRelease()
        } catch {
            downloadPhase = .failed(message: Self.describe(error))
            return
        }

        guard let asset = release.installerPackage else {
            // Honest fallback (rule 10, AGENTS.md): no signed package on this
            // release — point at the GitHub releases page instead of
            // guessing at a download. `localURL` here is a web URL, not a
            // local file; `isFileURL` is how callers tell the two apart.
            downloadPhase = .ready(
                localURL: release.htmlURL,
                humanInstructions: "This release doesn't have a downloadable installer package attached. "
                    + "Open the GitHub releases page, download the signed .pkg, then double-click it in Finder and "
                    + "complete Apple's Installer prompts. Return to Capsule and check again when installation finishes. "
                    + "Capsule never runs the installer for you."
            )
            return
        }

        downloadPhase = .downloading(fraction: nil)
        do {
            let localURL = try await download(asset.browserDownloadURL)
            downloadPhase = .ready(
                localURL: localURL,
                humanInstructions: "Downloaded \(asset.name), but the runtime has not been installed yet. Reveal the package "
                    + "in Finder, double-click it, and complete Apple's Installer prompts. Then return to Capsule and check "
                    + "again. Capsule never runs the installer for you. Release notes: \(release.htmlURL.absoluteString)"
            )
        } catch {
            downloadPhase = .failed(message: Self.describe(error))
        }
    }

    /// Resets a terminal `downloadPhase` (`.ready`/`.failed`) back to
    /// `.idle` — e.g. when the onboarding view or update banner is dismissed
    /// and later reopened.
    public func resetDownloadPhase() {
        downloadPhase = .idle
    }

    private static func searchedPaths(for error: any Error) -> [String] {
        if case RuntimeError.binaryNotFound(let searched) = error {
            return searched
        }
        return [
            "$\(ContainerBinaryLocator.environmentOverrideKey)",
            ContainerBinaryLocator.defaultInstallPath,
            "$PATH",
        ]
    }

    private static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// Real download implementation (production only — never exercised by
    /// unit tests, which inject `download`). Writes into a fresh scratch
    /// directory under the system temp directory, preserving the asset's
    /// real filename so Finder shows something meaningful when the
    /// onboarding view reveals it.
    private static func downloadToTemporaryFile(from url: URL) async throws -> URL {
        let (temporaryLocation, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capsule-runtime-installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        let destination = scratchDirectory.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: temporaryLocation, to: destination)
        return destination
    }
}
