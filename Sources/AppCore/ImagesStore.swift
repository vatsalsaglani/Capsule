import ContainerClient
import Foundation
import Observation

/// The testable state machine behind the Images screen (P1B B4 — AGENTS.md
/// rule 1: every feature drivable from a unit test against CapsuleKit, not a
/// View). Unlike `ContainerListStore`, there is no `RuntimeEvent` case for
/// image list changes (`RuntimeEvent` is container-scoped only), so this
/// store is deliberately on-demand: the view calls `refresh()` on appear and
/// this store calls it again itself after every mutation succeeds, rather
/// than subscribing to a bus.
///
/// No SwiftUI import here (mirrors `ContainerListStore`/`ContainerDetailStore`)
/// — `swift test` exercises this headless.
@MainActor
@Observable
public final class ImagesStore {
    public enum Phase: Equatable {
        case loading
        case loaded([ImageSummary])
        case failed(message: String)
    }

    /// State of the most recent (or in-flight) `pull(reference:platform:)`
    /// call. `lines` accumulates every `PullProgress.message` received so
    /// far — the view can render it as a scrolling console.
    public enum PullPhase: Equatable {
        case idle
        case pulling(lines: [String])
        case failed(message: String)
        case done
    }

    public struct ActionError: Equatable, Sendable {
        public let reference: String?
        public let message: String

        public init(reference: String?, message: String) {
            self.reference = reference
            self.message = message
        }
    }

    public private(set) var phase: Phase = .loading
    public private(set) var pullPhase: PullPhase = .idle
    public private(set) var lastActionError: ActionError?

    private let runtime: any ContainerRuntime

    /// `nonisolated(unsafe)` for the same reason as `ContainerDetailStore`'s
    /// task properties: `deinit` is nonisolated by language rule and must be
    /// able to cancel this, and `@ObservationIgnored` plumbing doesn't
    /// coexist with plain `nonisolated` on a mutable stored property under
    /// the `@Observable` macro expansion. Every other read/write happens on
    /// the main actor.
    @ObservationIgnored
    private nonisolated(unsafe) var pullTask: Task<Void, Never>?

    public init(runtime: any ContainerRuntime) {
        self.runtime = runtime
    }

    deinit {
        pullTask?.cancel()
    }

    // MARK: - Refresh

    public func refresh() async {
        do {
            let images = try await runtime.listImages()
            phase = .loaded(images)
        } catch {
            phase = .failed(message: message(for: error))
        }
    }

    // MARK: - Pull

    /// Starts (or restarts) a pull, replacing any previous `pullTask`.
    /// Progress lines accumulate into `pullPhase` as they arrive; a
    /// successful finish transitions to `.done` and triggers a `refresh()`
    /// (a pull is a mutation — the new/updated image should appear in the
    /// list without a separate manual refresh).
    public func pull(reference: String, platform: String?) {
        pullTask?.cancel()
        pullPhase = .pulling(lines: [])
        pullTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.runtime.pullImage(reference: reference, platform: platform)
                for try await progress in stream {
                    guard !Task.isCancelled else { return }
                    self.appendPullLine(progress.message)
                }
                guard !Task.isCancelled else { return }
                self.pullPhase = .done
                await self.refresh()
            } catch {
                guard !Task.isCancelled else { return }
                self.pullPhase = .failed(message: self.message(for: error))
            }
        }
    }

    /// Cancels an in-flight pull (if any) and resets `pullPhase` to `.idle` —
    /// the view calls this when the pull sheet is dismissed.
    public func dismissPull() {
        pullTask?.cancel()
        pullTask = nil
        pullPhase = .idle
    }

    private func appendPullLine(_ line: String) {
        if case .pulling(var lines) = pullPhase {
            lines.append(line)
            pullPhase = .pulling(lines: lines)
        } else {
            pullPhase = .pulling(lines: [line])
        }
    }

    // MARK: - Mutations

    public func tag(source: String, target: String) async {
        lastActionError = nil
        do {
            try await runtime.tagImage(source: source, target: target)
            await refresh()
        } catch {
            lastActionError = ActionError(reference: source, message: message(for: error))
        }
    }

    public func delete(reference: String) async {
        lastActionError = nil
        do {
            try await runtime.deleteImage(reference: reference)
            await refresh()
        } catch {
            lastActionError = ActionError(reference: reference, message: message(for: error))
        }
    }

    public func dismissActionError() {
        lastActionError = nil
    }

    // MARK: - Pure functions (unit-tested)

    /// `true` if any container in `containers` was created from `image`'s
    /// reference — the view passes `session.containers.currentContainers`
    /// for the cross-reference. Used to show an "in use" warning badge
    /// before a delete, not to block the delete itself (§6.1: warning, not a
    /// trap).
    public nonisolated static func isInUse(_ image: ImageSummary, byContainers containers: [ContainerSummary]) -> Bool {
        containers.contains { $0.imageReference == image.reference }
    }

    public func isInUse(_ image: ImageSummary, byContainers containers: [ContainerSummary]) -> Bool {
        Self.isInUse(image, byContainers: containers)
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
