import Foundation
import Testing
@testable import ContainerClient

// MARK: - RuntimeUpdateChecker.evaluate — pure, no network

@Test func evaluateReportsUpToDateWhenInstalledMatchesLatestTag() {
    let checker = RuntimeUpdateChecker()
    let status = checker.evaluate(installed: SemanticVersion(major: 1, minor: 1, patch: 0), latestTag: "1.1.0")
    #expect(status == .upToDate(current: SemanticVersion(major: 1, minor: 1, patch: 0)))
}

@Test func evaluateReportsUpdateAvailableWhenLatestTagIsNewer() {
    let checker = RuntimeUpdateChecker()
    let status = checker.evaluate(installed: SemanticVersion(major: 1, minor: 1, patch: 0), latestTag: "1.2.0")
    #expect(status == .updateAvailable(
        current: SemanticVersion(major: 1, minor: 1, patch: 0),
        latest: SemanticVersion(major: 1, minor: 2, patch: 0)
    ))
}

/// Rule 10 (AGENTS.md): Capsule targets `container` 1.x, but a major bump on
/// the upstream release must still surface as real news, never be hidden.
@Test func evaluateStillReportsUpdateAvailableAcrossAMajorVersionBump() {
    let checker = RuntimeUpdateChecker()
    let status = checker.evaluate(installed: SemanticVersion(major: 1, minor: 1, patch: 0), latestTag: "2.0.0")
    #expect(status == .updateAvailable(
        current: SemanticVersion(major: 1, minor: 1, patch: 0),
        latest: SemanticVersion(major: 2, minor: 0, patch: 0)
    ))
}

@Test func evaluateReportsUnknownWhenTagDoesNotParseAsSemanticVersion() {
    let checker = RuntimeUpdateChecker()
    let status = checker.evaluate(installed: SemanticVersion(major: 1, minor: 1, patch: 0), latestTag: "not-a-version")
    #expect(status == .unknown)
}

@Test func evaluateReportsUpToDateWhenInstalledIsNewerThanLatestTag() {
    // Shouldn't normally happen (installed can't outrun GitHub's latest), but
    // `evaluate` is a pure comparison — never claim an update when there
    // isn't one.
    let checker = RuntimeUpdateChecker()
    let status = checker.evaluate(installed: SemanticVersion(major: 1, minor: 2, patch: 0), latestTag: "1.1.0")
    #expect(status == .upToDate(current: SemanticVersion(major: 1, minor: 2, patch: 0)))
}

// MARK: - GitHubRelease.version / .installerPackage

/// apple/container tags are plain `x.y.z`, no `v` prefix (verified live
/// 2026-07-13 against `api.github.com/repos/apple/container/releases/latest`
/// — see `docs/learnings/2026-07-13-runtime-installer-release-assets.md`).
@Test func gitHubReleaseVersionParsesUnprefixedTag() {
    let release = GitHubRelease(tagName: "1.1.0", htmlURL: URL(string: "https://github.com/apple/container/releases/tag/1.1.0")!)
    #expect(release.version == SemanticVersion(major: 1, minor: 1, patch: 0))
}

/// A verified-live apple/container release has shipped two `.pkg` assets at
/// once (signed + unsigned) plus a non-installer `.zip` — `installerPackage`
/// must pick the signed one, not just the first `.pkg` in asset order.
@Test func installerPackagePrefersSignedPkgOverUnsignedAndIgnoresNonPkgAssets() {
    let release = GitHubRelease(
        tagName: "1.1.0",
        htmlURL: URL(string: "https://github.com/apple/container/releases/tag/1.1.0")!,
        assets: [
            .init(name: "container-installer-unsigned.pkg", browserDownloadURL: URL(string: "https://example.com/unsigned.pkg")!),
            .init(name: "container-dSYM.zip", browserDownloadURL: URL(string: "https://example.com/dsym.zip")!),
            .init(name: "container-1.1.0-installer-signed.pkg", browserDownloadURL: URL(string: "https://example.com/signed.pkg")!),
        ]
    )
    #expect(release.installerPackage?.name == "container-1.1.0-installer-signed.pkg")
}

@Test func installerPackageIsNilWhenNoPkgAssetIsAttached() {
    let release = GitHubRelease(
        tagName: "1.1.0",
        htmlURL: URL(string: "https://github.com/apple/container/releases/tag/1.1.0")!,
        assets: [.init(name: "container-dSYM.zip", browserDownloadURL: URL(string: "https://example.com/dsym.zip")!)]
    )
    #expect(release.installerPackage == nil)
}
