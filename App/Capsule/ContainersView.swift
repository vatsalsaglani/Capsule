import ContainerClient
import Observation
import SwiftUI

@MainActor @Observable
final class ContainersViewModel {
    enum Phase {
        case loading
        case unavailable(String)
        case loaded([ContainerSummary])
    }

    private(set) var phase: Phase = .loading
    private let runtime: (any ContainerRuntime)?

    init(runtime: (any ContainerRuntime)? = try? CLIProcessClient()) {
        self.runtime = runtime
    }

    /// MVP polling loop (plan §3): replaced by the Poller→EventBus pipeline
    /// during M1 without touching the view.
    func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func refresh() async {
        guard let runtime else {
            phase = .unavailable(
                "The `container` CLI was not found. Install it from github.com/apple/container/releases, then relaunch Capsule."
            )
            return
        }
        do {
            phase = .loaded(try await runtime.listContainers(all: true))
        } catch {
            phase = .unavailable(
                "The container runtime is not responding. Start it with `container system start`.\n\n\(error.localizedDescription)"
            )
        }
    }

    func start(_ container: ContainerSummary) async {
        try? await runtime?.startContainer(id: container.id)
        await refresh()
    }

    func stop(_ container: ContainerSummary) async {
        try? await runtime?.stopContainer(id: container.id)
        await refresh()
    }

    func delete(_ container: ContainerSummary) async {
        try? await runtime?.deleteContainer(id: container.id, force: false)
        await refresh()
    }
}

struct ContainersView: View {
    @State private var model = ContainersViewModel()

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView()
            case .unavailable(let message):
                ContentUnavailableView {
                    Label("Runtime Unavailable", systemImage: "shippingbox")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") {
                        Task { await model.refresh() }
                    }
                }
            case .loaded(let containers) where containers.isEmpty:
                ContentUnavailableView {
                    Label("No Containers", systemImage: "shippingbox")
                } description: {
                    Text("Run one with `container run …` — it appears here live.")
                }
            case .loaded(let containers):
                List(containers) { container in
                    ContainerRow(container: container, model: model)
                }
            }
        }
        .task { await model.poll() }
        .navigationTitle("Containers")
    }
}

struct ContainerRow: View {
    let container: ContainerSummary
    let model: ContainersViewModel

    var body: some View {
        HStack(spacing: 10) {
            StateDot(state: container.runState)
            VStack(alignment: .leading, spacing: 2) {
                Text(container.id)
                    .font(.body.weight(.medium))
                Text(container.imageReference ?? "unknown image")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(container.addresses.joined(separator: ", "))
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contextMenu {
            if container.runState == .running {
                Button("Stop") { Task { await model.stop(container) } }
            } else {
                Button("Start") { Task { await model.start(container) } }
            }
            Divider()
            Button("Delete", role: .destructive) {
                Task { await model.delete(container) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(container.id) — \(container.status)")
    }
}

/// Semantic state colors only — accent (indigo) never means state (plan §6.7).
struct StateDot: View {
    let state: ContainerRunState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch state {
        case .running: Color(nsColor: .systemGreen)
        case .stopped: Color(nsColor: .systemGray)
        case .unknown: Color(nsColor: .systemOrange)
        }
    }
}
