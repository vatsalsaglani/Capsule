import AppCore
import ContainerClient
import SwiftUI

/// One row in the Containers list — shared between the real Containers
/// screen (bound to the live `ContainerListStore`) and the `#if DEBUG` feel
/// prototype (bound to a scripted one), so the craft bar the prototype sets
/// is exactly what ships (P1B B2+B3 brief).
struct ContainerRow: View {
    let container: ContainerSummary
    let store: ContainerListStore

    var body: some View {
        HStack(spacing: 10) {
            ContainerStateDot(status: container.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(container.id)
                    .font(.body.weight(.medium))
                Text(container.imageReference ?? "unknown image")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !container.ports.isEmpty {
                Text(portsSummary)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contextMenu { rowActions }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var portsSummary: String {
        container.ports.map { "\($0.hostPort)→\($0.containerPort)" }.joined(separator: ", ")
    }

    private var accessibilityLabel: String {
        var label = "\(container.id) — \(container.status)"
        if !container.ports.isEmpty {
            label += ", port \(container.ports.map { String($0.hostPort) }.joined(separator: ", "))"
        }
        return label
    }

    @ViewBuilder
    private var rowActions: some View {
        if container.runState == .running {
            Button("Stop") { Task { await store.stopContainer(id: container.id) } }
            Button("Restart") { Task { await store.restartContainer(id: container.id) } }
        } else {
            Button("Start") { Task { await store.startContainer(id: container.id) } }
        }
        Divider()
        // Delete is instant + undoable in spirit (stopped ≠ deleted) — no
        // confirmation dialog per §6.1's forgiveness rule (confirmation is
        // reserved for the truly irreversible, e.g. volume delete).
        Button("Delete", role: .destructive) {
            Task { await store.deleteContainer(id: container.id, force: false) }
        }
    }
}
