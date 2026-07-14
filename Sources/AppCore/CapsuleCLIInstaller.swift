import Darwin
import Foundation
import Observation

/// The only command-link actions Capsule will perform. Replacement carries
/// the exact link text observed during inspection so execution can revalidate
/// it instead of accepting a generic "force" operation.
public enum CapsuleCLIInstallAction: Sendable, Equatable {
    case install
    case replaceStaleLink(expectedTarget: String)
}

/// A value-driven view of `/usr/local/bin/capsule`. Every actionable state
/// includes the narrowly-scoped action that was derived from that inspection.
public enum CapsuleCLIInstallationStatus: Sendable, Equatable {
    case unavailable(message: String)
    case notInstalled(action: CapsuleCLIInstallAction)
    case installed(destination: String)
    case staleLink(currentTarget: String, isBroken: Bool, action: CapsuleCLIInstallAction)
    case conflict(message: String)
}

public struct CapsuleCLIInstallerError: Error, Sendable, Equatable, LocalizedError {
    public let operation: String
    public let path: String
    public let code: Int32?
    public let detail: String

    public var errorDescription: String? {
        if let code {
            return "\(operation) failed for \(path): \(detail) (errno \(code))"
        }
        return "\(operation) failed for \(path): \(detail)"
    }

    public var isPermissionFailure: Bool {
        code == EACCES || code == EPERM
    }
}

/// Filesystem service for the app's bundled command-line tool. It only ever
/// creates Capsule's fixed symlink or replaces a link that inspection proved
/// points at an older `Capsule.app/Contents/Helpers/capsule` helper. Regular
/// files, directories, and foreign symlinks are never overwritten.
public struct CapsuleCLIInstaller: Sendable {
    public static let defaultDestinationURL = URL(fileURLWithPath: "/usr/local/bin/capsule")

    public let bundleURL: URL
    public let sourceURL: URL
    public let destinationURL: URL

    public init(
        bundleURL: URL,
        sourceURL: URL? = nil,
        destinationURL: URL = Self.defaultDestinationURL
    ) {
        self.bundleURL = bundleURL.standardizedFileURL
        self.sourceURL = (sourceURL
            ?? bundleURL.appendingPathComponent("Contents/Helpers/capsule", isDirectory: false))
            .standardizedFileURL
        self.destinationURL = destinationURL.standardizedFileURL
    }

    public init(bundle: Bundle = .main, destinationURL: URL = Self.defaultDestinationURL) {
        self.init(bundleURL: bundle.bundleURL, destinationURL: destinationURL)
    }

    public func inspect() -> CapsuleCLIInstallationStatus {
        do {
            try validateSource()
        } catch {
            return .unavailable(message: Self.describe(error))
        }

        do {
            return try inspectDestination()
        } catch {
            return .unavailable(message: Self.describe(error))
        }
    }

    /// Performs only an action returned by `inspect()`. Stale-link replacement
    /// additionally requires explicit confirmation and revalidates the raw
    /// link value immediately before unlinking it.
    @discardableResult
    public func perform(
        _ action: CapsuleCLIInstallAction,
        confirmingReplacement: Bool = false
    ) throws -> CapsuleCLIInstallationStatus {
        try validateSource()

        switch action {
        case .install:
            guard case .notInstalled = try inspectDestination() else {
                throw stateChangedError("the destination is no longer empty")
            }
            try createLink()

        case .replaceStaleLink(let expectedTarget):
            guard confirmingReplacement else {
                throw CapsuleCLIInstallerError(
                    operation: "Replace command link",
                    path: destinationURL.path,
                    code: nil,
                    detail: "explicit confirmation is required"
                )
            }
            guard case .staleLink(let currentTarget, _, _) = try inspectDestination(),
                  currentTarget == expectedTarget else {
                throw stateChangedError("the stale link changed after it was inspected")
            }
            try removeLink(expectedTarget: expectedTarget)
            do {
                try createLink()
            } catch {
                // Best-effort restoration keeps a failed update from silently
                // deleting the prior link. The original creation error remains
                // the one reported to the user.
                _ = expectedTarget.withCString { target in
                    destinationURL.path.withCString { destination in
                        Darwin.symlink(target, destination)
                    }
                }
                throw error
            }
        }

        let status = try inspectDestination()
        guard case .installed = status else {
            throw stateChangedError("the installed link could not be verified")
        }
        return status
    }

    /// A paste-only fallback for the common permission-denied case. The
    /// command deliberately has no `-f`: it cannot replace an unexpected file.
    public var manualInstallCommand: String {
        manualCommand(for: .install)
    }

    public func manualCommand(for action: CapsuleCLIInstallAction) -> String {
        let parent = destinationURL.deletingLastPathComponent().path
        let install = "/usr/bin/sudo /bin/mkdir -p \(Self.shellEscape(parent))"
            + " && /usr/bin/sudo /bin/ln -s \(Self.shellEscape(sourceURL.path))"
            + " \(Self.shellEscape(destinationURL.path))"
        switch action {
        case .install:
            return install
        case .replaceStaleLink(let expectedTarget):
            let destination = Self.shellEscape(destinationURL.path)
            let expected = Self.shellEscape(expectedTarget)
            return "if [ \"$(/usr/bin/readlink \(destination))\" = \(expected) ]; then "
                + "/usr/bin/sudo /bin/rm \(destination) && \(install); "
                + "else echo 'Capsule command link changed; nothing was replaced.'; fi"
        }
    }

    public static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Validation and inspection

    private func validateSource() throws {
        let lexicalBundle = bundleURL.standardizedFileURL.path
        let lexicalSource = sourceURL.standardizedFileURL.path
        guard Self.contains(path: lexicalSource, root: lexicalBundle) else {
            throw sourceError("the helper is outside the app bundle")
        }

        var info = stat()
        guard sourceURL.path.withCString({ Darwin.lstat($0, &info) }) == 0 else {
            throw posixError(operation: "Inspect bundled command", path: sourceURL.path)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw sourceError("the bundled helper is not a regular executable file")
        }
        guard sourceURL.path.withCString({ Darwin.access($0, X_OK) }) == 0 else {
            throw posixError(operation: "Validate bundled command executable", path: sourceURL.path)
        }

        let resolvedBundle = try resolvedExistingPath(bundleURL, operation: "Resolve app bundle")
        let resolvedSource = try resolvedExistingPath(sourceURL, operation: "Resolve bundled command")
        guard Self.contains(path: resolvedSource, root: resolvedBundle) else {
            throw sourceError("the resolved helper is outside the app bundle")
        }
    }

    private func inspectDestination() throws -> CapsuleCLIInstallationStatus {
        var info = stat()
        let result = destinationURL.path.withCString { Darwin.lstat($0, &info) }
        if result != 0 {
            if errno == ENOENT {
                return .notInstalled(action: .install)
            }
            throw posixError(operation: "Inspect command destination", path: destinationURL.path)
        }

        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            let target = try readLink(destinationURL)
            let resolvedTargetURL = resolvedLinkTarget(target)
            if resolvedTargetURL.standardizedFileURL.path == sourceURL.standardizedFileURL.path {
                return .installed(destination: destinationURL.path)
            }

            let isBroken = !Self.pathExistsFollowingLinks(resolvedTargetURL.path)
            if Self.isCapsuleHelperPath(resolvedTargetURL.path) {
                return .staleLink(
                    currentTarget: target,
                    isBroken: isBroken,
                    action: .replaceStaleLink(expectedTarget: target)
                )
            }

            let state = isBroken ? "broken" : "existing"
            return .conflict(
                message: "\(destinationURL.path) is a \(state) foreign symlink to \(target). Capsule will not replace it."
            )

        case S_IFREG:
            return .conflict(
                message: "\(destinationURL.path) is a regular file. Capsule will not replace it."
            )

        case S_IFDIR:
            return .conflict(
                message: "\(destinationURL.path) is a directory. Capsule will not replace it."
            )

        default:
            return .conflict(
                message: "\(destinationURL.path) already exists and is not a symlink Capsule can manage."
            )
        }
    }

    private func resolvedLinkTarget(_ target: String) -> URL {
        if target.hasPrefix("/") {
            return URL(fileURLWithPath: target).standardizedFileURL
        }
        return destinationURL.deletingLastPathComponent()
            .appendingPathComponent(target)
            .standardizedFileURL
    }

    private func createLink() throws {
        let result = sourceURL.path.withCString { source in
            destinationURL.path.withCString { destination in
                Darwin.symlink(source, destination)
            }
        }
        guard result == 0 else {
            throw posixError(operation: "Install command link", path: destinationURL.path)
        }
    }

    private func removeLink(expectedTarget: String) throws {
        var info = stat()
        guard destinationURL.path.withCString({ Darwin.lstat($0, &info) }) == 0,
              (info.st_mode & S_IFMT) == S_IFLNK,
              try readLink(destinationURL) == expectedTarget else {
            throw stateChangedError("the stale link changed before it could be replaced")
        }
        guard destinationURL.path.withCString({ Darwin.unlink($0) }) == 0 else {
            throw posixError(operation: "Remove stale command link", path: destinationURL.path)
        }
    }

    private func readLink(_ url: URL) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = url.path.withCString { Darwin.readlink($0, &buffer, buffer.count - 1) }
        guard count >= 0 else {
            throw posixError(operation: "Read command link", path: url.path)
        }
        let bytes = buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func resolvedExistingPath(_ url: URL, operation: String) throws -> String {
        guard let pointer = url.path.withCString({ Darwin.realpath($0, nil) }) else {
            throw posixError(operation: operation, path: url.path)
        }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    private func sourceError(_ detail: String) -> CapsuleCLIInstallerError {
        CapsuleCLIInstallerError(
            operation: "Validate bundled command",
            path: sourceURL.path,
            code: nil,
            detail: detail
        )
    }

    private func stateChangedError(_ detail: String) -> CapsuleCLIInstallerError {
        CapsuleCLIInstallerError(
            operation: "Install command link",
            path: destinationURL.path,
            code: nil,
            detail: detail
        )
    }

    private func posixError(operation: String, path: String) -> CapsuleCLIInstallerError {
        let code = errno
        return CapsuleCLIInstallerError(
            operation: operation,
            path: path,
            code: code,
            detail: String(cString: strerror(code))
        )
    }

    private static func contains(path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func pathExistsFollowingLinks(_ path: String) -> Bool {
        path.withCString { Darwin.access($0, F_OK) } == 0
    }

    private static func isCapsuleHelperPath(_ path: String) -> Bool {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard components.count >= 4 else { return false }
        return components.suffix(4) == ["Capsule.app", "Contents", "Helpers", "capsule"]
    }

    private static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

public enum CapsuleCLIInstallPhase: Sendable, Equatable {
    case checking
    case working
    case ready(CapsuleCLIInstallationStatus)
    case permissionRequired(message: String, manualCommand: String)
    case failed(message: String)
}

/// Main-actor state for SwiftUI. The view receives only typed status/actions;
/// all filesystem policy remains in the testable installer above.
@MainActor
@Observable
public final class CapsuleCLIInstallStore {
    public private(set) var phase: CapsuleCLIInstallPhase = .checking

    private let installer: CapsuleCLIInstaller

    public init(installer: CapsuleCLIInstaller = CapsuleCLIInstaller()) {
        self.installer = installer
    }

    public func refresh() {
        phase = .checking
        phase = .ready(installer.inspect())
    }

    public func perform(_ action: CapsuleCLIInstallAction, confirmingReplacement: Bool = false) {
        phase = .working
        do {
            phase = .ready(try installer.perform(action, confirmingReplacement: confirmingReplacement))
        } catch let error as CapsuleCLIInstallerError where
            error.isPermissionFailure
                || (error.operation == "Install command link" && error.code == ENOENT)
        {
            phase = .permissionRequired(
                message: error.localizedDescription,
                manualCommand: installer.manualCommand(for: action)
            )
        } catch {
            phase = .failed(message: Self.describe(error))
        }
    }

    private static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
