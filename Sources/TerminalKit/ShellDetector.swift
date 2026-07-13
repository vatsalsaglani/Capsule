import ContainerClient
import Foundation

/// Which shell to hand to `PTYExecSession` for a given container. S3
/// grounded the fallback order against real images: alpine has `sh`/`ash`
/// (busybox, no `bash`); debian has `sh`/`bash`/`dash` (no `ash`). Every
/// image tested has `/bin/sh` at minimum, so `sh` connects in practice on
/// both — `bash`/`ash` only matter for images lacking even `sh`.
public enum ShellDetector {
    /// Order per master plan §3 / S3: `sh` → `bash` → `ash`.
    public static let candidateOrder = ["sh", "bash", "ash"]

    public enum DetectionError: Error, Sendable, Equatable {
        case noShellFound(containerID: String, tried: [String])
    }

    /// Probes each candidate with a non-interactive `<candidate> -c "exit
    /// 0"` via `ContainerRuntime.exec` (never PTY — this is P1A's
    /// non-interactive exec, deliberately not `PTYExecSession`); the first
    /// exit-0 candidate wins. Throws `DetectionError.noShellFound` naming
    /// every shell that was tried if none work.
    public static func detectShell(
        containerID: String,
        runtime: any ContainerRuntime,
        probeTimeout: Duration = .seconds(5)
    ) async throws -> String {
        var tried: [String] = []
        for candidate in candidateOrder {
            tried.append(candidate)
            do {
                let result = try await runtime.exec(
                    id: containerID,
                    argv: [candidate, "-c", "exit 0"],
                    timeout: probeTimeout
                )
                if result.exitCode == 0 {
                    return candidate
                }
            } catch {
                // Treat a probe failure (missing binary, exec error) the
                // same as a non-zero exit: just try the next candidate.
                continue
            }
        }
        throw DetectionError.noShellFound(containerID: containerID, tried: tried)
    }
}
