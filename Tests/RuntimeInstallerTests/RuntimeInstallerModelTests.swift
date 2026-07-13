import ContainerClient
import ContainerClientTestSupport
import Foundation
import RuntimeInstaller
import Testing

private struct ProbeError: Error, Sendable, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func makeRelease(
    tag: String,
    assets: [GitHubRelease.Asset] = [],
    htmlURL: URL = URL(string: "https://github.com/apple/container/releases/tag/x")!
) -> GitHubRelease {
    GitHubRelease(tagName: tag, htmlURL: htmlURL, assets: assets)
}

// MARK: - 1. Presence via refresh()

@Test @MainActor
func refreshReportsMissingWhenRuntimeFactoryThrowsBinaryNotFound() async {
    let model = RuntimeInstallerModel(
        runtimeFactory: { throw RuntimeError.binaryNotFound(searched: ["$CAPSULE_CONTAINER_BIN", "/usr/local/bin/container", "$PATH"]) },
        fetchLatestRelease: { makeRelease(tag: "1.1.0") },
        download: { _ in throw ProbeError(message: "should never be called") }
    )

    await model.refresh()

    guard case .missing(let searched) = model.runtimePresence else {
        Issue.record("expected .missing, got \(model.runtimePresence)")
        return
    }
    #expect(searched == ["$CAPSULE_CONTAINER_BIN", "/usr/local/bin/container", "$PATH"])
    #expect(model.updateStatus == nil)
}

@Test @MainActor
func refreshReportsPresentAndUpdateAvailableWhenLatestReleaseIsNewer() async {
    let fake = FakeContainerRuntime()
    await fake.setCLIVersion(SemanticVersion(major: 1, minor: 0, patch: 0))
    let model = RuntimeInstallerModel(
        runtimeFactory: { fake },
        fetchLatestRelease: { makeRelease(tag: "1.2.0") },
        download: { _ in throw ProbeError(message: "should never be called") }
    )

    await model.refresh()

    guard case .present(let version) = model.runtimePresence else {
        Issue.record("expected .present, got \(model.runtimePresence)")
        return
    }
    #expect(version == SemanticVersion(major: 1, minor: 0, patch: 0))
    #expect(model.updateStatus == .updateAvailable(
        current: SemanticVersion(major: 1, minor: 0, patch: 0),
        latest: SemanticVersion(major: 1, minor: 2, patch: 0)
    ))
}

@Test @MainActor
func refreshReportsUpToDateWhenInstalledMatchesLatest() async {
    let fake = FakeContainerRuntime()
    await fake.setCLIVersion(SemanticVersion(major: 1, minor: 1, patch: 0))
    let model = RuntimeInstallerModel(
        runtimeFactory: { fake },
        fetchLatestRelease: { makeRelease(tag: "1.1.0") },
        download: { _ in throw ProbeError(message: "should never be called") }
    )

    await model.refresh()

    #expect(model.runtimePresence == .present(version: SemanticVersion(major: 1, minor: 1, patch: 0)))
    #expect(model.updateStatus == .upToDate(current: SemanticVersion(major: 1, minor: 1, patch: 0)))
}

@Test @MainActor
func refreshDegradesUpdateStatusToNilOnNetworkFailureWithoutHidingPresence() async {
    let fake = FakeContainerRuntime()
    await fake.setCLIVersion(SemanticVersion(major: 1, minor: 1, patch: 0))
    let model = RuntimeInstallerModel(
        runtimeFactory: { fake },
        fetchLatestRelease: { throw ProbeError(message: "no network") },
        download: { _ in throw ProbeError(message: "should never be called") }
    )

    await model.refresh()

    #expect(model.runtimePresence == .present(version: SemanticVersion(major: 1, minor: 1, patch: 0)))
    #expect(model.updateStatus == nil)
}

// MARK: - 2. prepareInstaller()

@Test @MainActor
func prepareInstallerDownloadsThePkgAndReportsHonestInstructions() async {
    let pkgURL = URL(string: "https://github.com/apple/container/releases/download/1.2.0/container-1.2.0-installer-signed.pkg")!
    let localFile = URL(fileURLWithPath: "/tmp/capsule-fixture/container-1.2.0-installer-signed.pkg")
    var downloadedURL: URL?
    let model = RuntimeInstallerModel(
        runtimeFactory: { FakeContainerRuntime() },
        fetchLatestRelease: {
            makeRelease(tag: "1.2.0", assets: [
                GitHubRelease.Asset(name: "container-1.2.0-installer-signed.pkg", browserDownloadURL: pkgURL),
            ])
        },
        download: { url in
            downloadedURL = url
            return localFile
        }
    )

    await model.prepareInstaller()

    #expect(downloadedURL == pkgURL)
    guard case .ready(let localURL, let instructions) = model.downloadPhase else {
        Issue.record("expected .ready, got \(model.downloadPhase)")
        return
    }
    #expect(localURL == localFile)
    #expect(localURL.isFileURL)
    assertInstructionsNeverImplyAutoInstall(instructions)
}

@Test @MainActor
func prepareInstallerFallsBackToReleasePageWhenNoPkgAssetExists() async {
    let releaseURL = URL(string: "https://github.com/apple/container/releases/tag/1.2.0")!
    let model = RuntimeInstallerModel(
        runtimeFactory: { FakeContainerRuntime() },
        fetchLatestRelease: {
            makeRelease(tag: "1.2.0", assets: [
                GitHubRelease.Asset(name: "container-dSYM.zip", browserDownloadURL: releaseURL),
            ], htmlURL: releaseURL)
        },
        download: { _ in throw ProbeError(message: "should never be called — no .pkg asset") }
    )

    await model.prepareInstaller()

    guard case .ready(let localURL, let instructions) = model.downloadPhase else {
        Issue.record("expected .ready fallback, got \(model.downloadPhase)")
        return
    }
    #expect(localURL == releaseURL)
    #expect(!localURL.isFileURL)
    assertInstructionsNeverImplyAutoInstall(instructions)
}

@Test @MainActor
func prepareInstallerPrefersSignedPkgOverUnsignedWhenBothArePresent() async {
    let unsignedURL = URL(string: "https://github.com/apple/container/releases/download/1.2.0/container-installer-unsigned.pkg")!
    let signedURL = URL(string: "https://github.com/apple/container/releases/download/1.2.0/container-1.2.0-installer-signed.pkg")!
    let release = makeRelease(tag: "1.2.0", assets: [
        GitHubRelease.Asset(name: "container-installer-unsigned.pkg", browserDownloadURL: unsignedURL),
        GitHubRelease.Asset(name: "container-1.2.0-installer-signed.pkg", browserDownloadURL: signedURL),
    ])

    #expect(release.installerPackage?.browserDownloadURL == signedURL)
}

@Test @MainActor
func prepareInstallerReportsFailedOnReleaseFetchFailure() async {
    let model = RuntimeInstallerModel(
        runtimeFactory: { FakeContainerRuntime() },
        fetchLatestRelease: { throw ProbeError(message: "GitHub is unreachable") },
        download: { _ in throw ProbeError(message: "should never be called") }
    )

    await model.prepareInstaller()

    guard case .failed(let message) = model.downloadPhase else {
        Issue.record("expected .failed, got \(model.downloadPhase)")
        return
    }
    #expect(message.contains("GitHub is unreachable"))
}

@Test @MainActor
func prepareInstallerReportsFailedOnDownloadFailure() async {
    let pkgURL = URL(string: "https://github.com/apple/container/releases/download/1.2.0/container-1.2.0-installer-signed.pkg")!
    let model = RuntimeInstallerModel(
        runtimeFactory: { FakeContainerRuntime() },
        fetchLatestRelease: {
            makeRelease(tag: "1.2.0", assets: [
                GitHubRelease.Asset(name: "container-1.2.0-installer-signed.pkg", browserDownloadURL: pkgURL),
            ])
        },
        download: { _ in throw ProbeError(message: "disk full") }
    )

    await model.prepareInstaller()

    guard case .failed(let message) = model.downloadPhase else {
        Issue.record("expected .failed, got \(model.downloadPhase)")
        return
    }
    #expect(message.contains("disk full"))
}

@Test @MainActor
func resetDownloadPhaseReturnsToIdle() async {
    let model = RuntimeInstallerModel(
        runtimeFactory: { FakeContainerRuntime() },
        fetchLatestRelease: { throw ProbeError(message: "unreachable") },
        download: { _ in throw ProbeError(message: "should never be called") }
    )

    await model.prepareInstaller()
    #expect(model.downloadPhase != .idle)
    model.resetDownloadPhase()
    #expect(model.downloadPhase == .idle)
}

// MARK: - 3. Rule 7 — the seam only downloads + reports, it never installs

/// There is no `installInstaller()`/`runInstaller()`/`sudo` API on
/// `RuntimeInstallerModel` at all — the type only exposes `refresh()` and
/// `prepareInstaller()`. This test pins that surface down (a future PR
/// widening it to actually execute the `.pkg` would have to add a new,
/// clearly-named method, not silently repurpose one of these two) and pins
/// the copy shown to the user so it never implies auto-install.
@Test @MainActor
func prepareInstallerNeverInvokesTheRuntimeFactoryAsInstallExecution() async {
    var runtimeFactoryCallCount = 0
    let pkgURL = URL(string: "https://github.com/apple/container/releases/download/1.2.0/container-1.2.0-installer-signed.pkg")!
    let model = RuntimeInstallerModel(
        runtimeFactory: {
            runtimeFactoryCallCount += 1
            return FakeContainerRuntime()
        },
        fetchLatestRelease: {
            makeRelease(tag: "1.2.0", assets: [
                GitHubRelease.Asset(name: "container-1.2.0-installer-signed.pkg", browserDownloadURL: pkgURL),
            ])
        },
        download: { _ in URL(fileURLWithPath: "/tmp/capsule-fixture/container-1.2.0-installer-signed.pkg") }
    )

    await model.prepareInstaller()

    // prepareInstaller() only resolves + downloads; it never touches the
    // runtime at all (nothing to "install into" — the seam is download-only).
    #expect(runtimeFactoryCallCount == 0)
}

@MainActor
private func assertInstructionsNeverImplyAutoInstall(_ instructions: String) {
    let lowered = instructions.lowercased()
    #expect(!lowered.contains("sudo"))
    #expect(!lowered.contains("installer -pkg"))
    #expect(!lowered.contains("we installed") && !lowered.contains("we'll install") && !lowered.contains("installing for you"))
    #expect(lowered.contains("never") || lowered.contains("yourself"))
}
