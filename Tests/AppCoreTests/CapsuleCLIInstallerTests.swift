import AppCore
import Darwin
import Foundation
import Testing

private struct CLIInstallerFixture {
    let root: URL
    let bundle: URL
    let source: URL
    let destination: URL
    let installer: CapsuleCLIInstaller

    init(executable: Bool = true, name: String = UUID().uuidString) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CapsuleCLIInstallerTests-\(name)", isDirectory: true)
        bundle = root.appendingPathComponent("Capsule.app", isDirectory: true)
        source = bundle.appendingPathComponent("Contents/Helpers/capsule", isDirectory: false)
        destination = root.appendingPathComponent("bin/capsule", isDirectory: false)

        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        #expect(FileManager.default.createFile(atPath: source.path, contents: Data("fixture".utf8)))
        #expect(chmod(source.path, executable ? 0o755 : 0o644) == 0)

        installer = CapsuleCLIInstaller(
            bundleURL: bundle,
            sourceURL: source,
            destinationURL: destination
        )
    }

    func cleanup() {
        _ = chmod(destination.deletingLastPathComponent().path, 0o755)
        try? FileManager.default.removeItem(at: root)
    }
}

@Test func bundledCommandMissingIsUnavailableWithRealPath() throws {
    let fixture = try CLIInstallerFixture()
    defer { fixture.cleanup() }
    try FileManager.default.removeItem(at: fixture.source)

    guard case .unavailable(let message) = fixture.installer.inspect() else {
        Issue.record("expected unavailable status")
        return
    }
    #expect(message.contains(fixture.source.path))
    #expect(message.contains("No such file or directory"))
}

@Test func bundledCommandMustBeExecutable() throws {
    let fixture = try CLIInstallerFixture(executable: false)
    defer { fixture.cleanup() }

    guard case .unavailable(let message) = fixture.installer.inspect() else {
        Issue.record("expected unavailable status")
        return
    }
    #expect(message.contains("executable"))
    #expect(message.contains("Permission denied"))
}

@Test func bundledCommandResolvedOutsideBundleIsRejected() throws {
    let fixture = try CLIInstallerFixture()
    defer { fixture.cleanup() }
    let outside = fixture.root.appendingPathComponent("outside-capsule")
    #expect(FileManager.default.createFile(atPath: outside.path, contents: Data("outside".utf8)))
    #expect(chmod(outside.path, 0o755) == 0)
    try FileManager.default.removeItem(at: fixture.source)
    try FileManager.default.createSymbolicLink(at: fixture.source, withDestinationURL: outside)

    guard case .unavailable(let message) = fixture.installer.inspect() else {
        Issue.record("expected unavailable status")
        return
    }
    #expect(message.contains("not a regular executable file"))
}

@Test func missingDestinationOffersOnlyExactInstallAction() throws {
    let fixture = try CLIInstallerFixture()
    defer { fixture.cleanup() }

    #expect(fixture.installer.inspect() == .notInstalled(action: .install))
}

@Test func installCreatesExactAbsoluteLinkAndIsIdempotent() throws {
    let fixture = try CLIInstallerFixture()
    defer { fixture.cleanup() }

    let status = try fixture.installer.perform(.install)
    #expect(status == .installed(destination: fixture.destination.path))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.destination.path) == fixture.source.path)
    #expect(fixture.installer.inspect() == .installed(destination: fixture.destination.path))

    #expect(throws: CapsuleCLIInstallerError.self) {
        try fixture.installer.perform(.install)
    }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.destination.path) == fixture.source.path)
}

@Test func relativeLinkResolvingToCurrentHelperCountsAsInstalled() throws {
    let fixture = try CLIInstallerFixture()
    defer { fixture.cleanup() }
    let relativeTarget = "../Capsule.app/Contents/Helpers/capsule"
    try FileManager.default.createSymbolicLink(
        atPath: fixture.destination.path,
        withDestinationPath: relativeTarget
    )

    #expect(fixture.installer.inspect() == .installed(destination: fixture.destination.path))
}

@Test func staleBrokenRelativeCapsuleLinkRequiresConfirmationThenUpdates() throws {
    let fixture = try CLIInstallerFixture()
    defer { fixture.cleanup() }
    let staleTarget = "../Old/Capsule.app/Contents/Helpers/capsule"
    try FileManager.default.createSymbolicLink(
        atPath: fixture.destination.path,
        withDestinationPath: staleTarget
    )

    let action = CapsuleCLIInstallAction.replaceStaleLink(expectedTarget: staleTarget)
    #expect(fixture.installer.inspect() == .staleLink(
        currentTarget: staleTarget,
        isBroken: true,
        action: action
    ))

    #expect(throws: CapsuleCLIInstallerError.self) {
        try fixture.installer.perform(action)
    }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.destination.path) == staleTarget)

    #expect(try fixture.installer.perform(action, confirmingReplacement: true)
        == .installed(destination: fixture.destination.path))
}

@Test func staleReplacementRevalidatesExpectedLinkText() throws {
    let fixture = try CLIInstallerFixture()
    defer { fixture.cleanup() }
    let staleTarget = "../Old/Capsule.app/Contents/Helpers/capsule"
    let changedTarget = "../someone-else"
    try FileManager.default.createSymbolicLink(atPath: fixture.destination.path, withDestinationPath: staleTarget)
    let action = CapsuleCLIInstallAction.replaceStaleLink(expectedTarget: staleTarget)
    try FileManager.default.removeItem(at: fixture.destination)
    try FileManager.default.createSymbolicLink(atPath: fixture.destination.path, withDestinationPath: changedTarget)

    #expect(throws: CapsuleCLIInstallerError.self) {
        try fixture.installer.perform(action, confirmingReplacement: true)
    }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.destination.path) == changedTarget)
}

@Test func regularFileConflictIsPreserved() throws {
    let fixture = try CLIInstallerFixture()
    defer { fixture.cleanup() }
    let original = Data("existing command".utf8)
    #expect(FileManager.default.createFile(atPath: fixture.destination.path, contents: original))

    guard case .conflict(let message) = fixture.installer.inspect() else {
        Issue.record("expected conflict")
        return
    }
    #expect(message.contains("regular file"))
    #expect(throws: CapsuleCLIInstallerError.self) {
        try fixture.installer.perform(.install)
    }
    #expect(try Data(contentsOf: fixture.destination) == original)
}

@Test func foreignSymlinkConflictIsPreserved() throws {
    let fixture = try CLIInstallerFixture()
    defer { fixture.cleanup() }
    let foreignTarget = "../another-tool"
    try FileManager.default.createSymbolicLink(atPath: fixture.destination.path, withDestinationPath: foreignTarget)

    guard case .conflict(let message) = fixture.installer.inspect() else {
        Issue.record("expected conflict")
        return
    }
    #expect(message.contains("foreign symlink"))
    #expect(throws: CapsuleCLIInstallerError.self) {
        try fixture.installer.perform(.install)
    }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.destination.path) == foreignTarget)
}

@Test @MainActor
func permissionFailureProvidesShellEscapedManualFallback() throws {
    let fixture = try CLIInstallerFixture(name: "Capsule's CLI")
    defer { fixture.cleanup() }
    #expect(chmod(fixture.destination.deletingLastPathComponent().path, 0o555) == 0)
    let store = CapsuleCLIInstallStore(installer: fixture.installer)

    store.perform(.install)

    guard case .permissionRequired(let message, let command) = store.phase else {
        Issue.record("expected permission-required status, got \(store.phase)")
        return
    }
    #expect(message.contains("Permission denied"))
    #expect(command.contains("/usr/bin/sudo"))
    #expect(command.contains("'\\''"))
    #expect(!command.contains(" -f "))
    #expect(command.hasSuffix(CapsuleCLIInstaller.shellEscape(fixture.destination.path)))
}

@Test @MainActor
func missingDestinationParentProvidesMkdirManualFallback() throws {
    let fixture = try CLIInstallerFixture()
    defer { fixture.cleanup() }
    let destinationParent = fixture.destination.deletingLastPathComponent()
    try FileManager.default.removeItem(at: destinationParent)
    let store = CapsuleCLIInstallStore(installer: fixture.installer)

    store.perform(.install)

    guard case .permissionRequired(let message, let command) = store.phase else {
        Issue.record("expected permission-required status, got \(store.phase)")
        return
    }
    #expect(message.contains("No such file or directory"))
    #expect(command.contains("/usr/bin/sudo /bin/mkdir -p \(CapsuleCLIInstaller.shellEscape(destinationParent.path))"))
    #expect(command.hasSuffix(CapsuleCLIInstaller.shellEscape(fixture.destination.path)))
}

@Test func staleManualFallbackRevalidatesBeforeRemovingLink() throws {
    let fixture = try CLIInstallerFixture()
    defer { fixture.cleanup() }
    let target = "../Old Capsule.app/../Capsule.app/Contents/Helpers/capsule"
    let action = CapsuleCLIInstallAction.replaceStaleLink(expectedTarget: target)

    let command = fixture.installer.manualCommand(for: action)

    #expect(command.contains("/usr/bin/readlink"))
    #expect(command.contains(CapsuleCLIInstaller.shellEscape(target)))
    #expect(command.contains("nothing was replaced"))
    #expect(!command.contains(" -f "))
}
