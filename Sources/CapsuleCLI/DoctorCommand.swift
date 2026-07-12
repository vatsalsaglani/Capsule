import ArgumentParser
import ContainerClient

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Diagnose the Apple container runtime installation."
    )

    @Flag(help: "Skip the GitHub latest-release check.")
    var offline = false

    func run() async throws {
        guard let binaryPath = ContainerBinaryLocator.locate() else {
            print("✗ container CLI not found")
            print("  Looked at $\(ContainerBinaryLocator.environmentOverrideKey), \(ContainerBinaryLocator.defaultInstallPath), and $PATH.")
            print("  Install the signed package from https://github.com/apple/container/releases")
            throw ExitCode(1)
        }
        print("✓ container CLI at \(binaryPath)")

        let client = try CLIProcessClient(binaryPath: binaryPath)
        var failures = 0
        var installedVersion: SemanticVersion?

        do {
            let version = try await client.cliVersion()
            installedVersion = version
            if version.major >= 1 {
                print("✓ container version \(version) (Capsule is developed against 1.1.x)")
            } else {
                print("⚠ container version \(version) — Capsule requires 1.x")
                failures += 1
            }
        } catch {
            print("✗ could not read container version: \(error.localizedDescription)")
            failures += 1
        }

        do {
            let status = try await client.systemStatus()
            if status.isRunning {
                print("✓ runtime apiserver is running")
            } else {
                print("⚠ runtime is not running — start it with `container system start`")
            }
        } catch {
            print("⚠ could not query runtime status — start it with `container system start`")
            print("  (\(error.localizedDescription))")
        }

        if !offline {
            await checkForUpdates(installedVersion: installedVersion)
        }

        if failures > 0 { throw ExitCode(1) }
    }

    private func checkForUpdates(installedVersion: SemanticVersion?) async {
        guard let installedVersion else { return }
        do {
            if let release = try await RuntimeUpdateChecker().updateAvailable(installed: installedVersion) {
                print("⚠ runtime update available: \(installedVersion) → \(release.version.map(String.init(describing:)) ?? release.tagName)")
                print("  \(release.htmlURL)")
            } else {
                print("✓ runtime is up to date with the latest GitHub release")
            }
        } catch {
            print("⚠ could not reach GitHub for the update check (pass --offline to skip)")
        }
    }
}
