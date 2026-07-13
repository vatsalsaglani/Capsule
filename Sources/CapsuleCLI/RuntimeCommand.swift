import ArgumentParser
import ContainerClient

/// `capsule runtime` — install/update visibility for the `container` CLI
/// dependency (P1D). Coordinated single-tree touch: `CapsuleCLI` is
/// nominally P2B-owned, but P1D's CLI smoke needs a real subcommand here and
/// no P2B worktree exists yet — same append-only-registration precedent as
/// the earlier `DoctorCommand` ripple.
struct RuntimeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runtime",
        abstract: "Inspect the Apple `container` runtime dependency.",
        subcommands: [
            RuntimeStatusCommand.self,
        ]
    )
}

/// Thin over `ContainerBinaryLocator` + `CLIProcessClient` +
/// `RuntimeUpdateChecker` (rule 1, AGENTS.md — no logic here beyond
/// formatting). Truthful in every branch: a missing binary prints exactly
/// what was searched and where to get it, never a stack trace (rule 7); a
/// network failure during the update check degrades to a plain "could not
/// check" line rather than failing the whole command.
struct RuntimeStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the installed `container` binary, version, apiserver state, and update status."
    )

    @Flag(help: "Skip the GitHub latest-release check.")
    var offline = false

    func run() async throws {
        guard let binaryPath = ContainerBinaryLocator.locate() else {
            print("✗ container CLI not found")
            print("  Searched: $\(ContainerBinaryLocator.environmentOverrideKey), \(ContainerBinaryLocator.defaultInstallPath), $PATH")
            print("  Install the signed package from https://github.com/apple/container/releases")
            print("  Capsule never installs it for you — download the .pkg and run it yourself.")
            throw ExitCode(1)
        }
        print("Binary:  \(binaryPath)")

        let client = try CLIProcessClient(binaryPath: binaryPath)

        var installedVersion: SemanticVersion?
        do {
            let version = try await client.cliVersion()
            installedVersion = version
            print("Version: \(version)")
        } catch {
            print("Version: could not read (\(error.localizedDescription))")
        }

        do {
            let status = try await client.systemStatus()
            print("Running: \(status.isRunning ? "yes" : "no")")
        } catch {
            print("Running: could not query (\(error.localizedDescription))")
        }

        if offline {
            print("Update:  skipped (--offline)")
            return
        }
        await printUpdateStatus(installedVersion: installedVersion)
    }

    private func printUpdateStatus(installedVersion: SemanticVersion?) async {
        guard let installedVersion else {
            print("Update:  unknown — no installed version to compare")
            return
        }
        let checker = RuntimeUpdateChecker()
        do {
            let release = try await checker.latestRelease()
            switch checker.evaluate(installed: installedVersion, latestTag: release.tagName) {
            case .upToDate:
                print("Update:  up to date with the latest GitHub release")
            case .updateAvailable(let current, let latest):
                print("Update:  available (\(current) → \(latest))")
                print("         \(release.htmlURL)")
            case .unknown:
                print("Update:  unknown — could not parse a version from release tag \"\(release.tagName)\"")
            }
        } catch {
            print("Update:  could not check for updates (pass --offline to skip)")
        }
    }
}
