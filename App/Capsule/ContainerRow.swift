import AppCore
import ContainerClient
import SwiftUI

struct ContainerRow: View {
    let container: ContainerSummary
    let store: ContainerListStore
    let layout: CapsuleResourceSurfaceLayout
    let isSelected: Bool
    let sample: StatsSample?
    let select: () -> Void

    var body: some View {
        CapsuleResourceSurface(
            layout: layout,
            isSelected: isSelected,
            accessibilityLabel: accessibilityLabel,
            select: select
        ) {
            summary
        } actions: {
            actionButtons
        }
        .contextMenu { actionMenu }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: layout == .card ? 10 : 5) {
            HStack(spacing: 8) {
                ContainerStateDot(status: container.status)
                Text(container.id)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(container.status.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ContainerStateColor.color(for: container.status))
            }
            Text(container.imageReference ?? "Unknown image")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if layout == .row {
                HStack {
                    Text(portsSummary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let sample {
                        Label(CapsuleFormatting.bytes(sample.memoryUsageBytes), systemImage: "memorychip")
                            .font(.caption.monospacedDigit().weight(.medium))
                    }
                }
            } else {
                Label(portsSummary, systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let sample {
                    CapsuleMetricView(
                        title: "Memory",
                        value: CapsuleFormatting.memory(sample.memoryUsageBytes, limit: sample.memoryLimitBytes),
                        fraction: CapsuleFormatting.fraction(sample.memoryUsageBytes, of: sample.memoryLimitBytes)
                    )
                } else {
                    Text(container.runState == .running ? "Collecting memory…" : "Memory available while running")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var portsSummary: String {
        guard !container.ports.isEmpty else { return "No published ports" }
        return container.ports.map { "\($0.hostPort)→\($0.containerPort)" }.joined(separator: ", ")
    }

    private var accessibilityLabel: String {
        var label = "\(container.id), \(container.status)"
        if let sample { label += ", \(CapsuleFormatting.bytes(sample.memoryUsageBytes)) memory" }
        return label
    }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            if container.runState == .running {
                actionButton("Stop", symbol: "stop.fill") {
                    await store.stopContainer(id: container.id)
                }
                actionButton("Restart", symbol: "arrow.clockwise") {
                    await store.restartContainer(id: container.id)
                }
            } else {
                actionButton("Start", symbol: "play.fill", tint: CapsulePalette.accent) {
                    await store.startContainer(id: container.id)
                }
            }
            actionButton("Delete", symbol: "trash", tint: Color(nsColor: .systemRed)) {
                await store.deleteContainer(id: container.id, force: false)
            }
        }
    }

    private func actionButton(
        _ title: String,
        symbol: String,
        tint: Color = .secondary,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        Button(title, systemImage: symbol) {
            Task { await action() }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(tint)
        .help("\(title) \(container.id)")
    }

    @ViewBuilder
    private var actionMenu: some View {
        if container.runState == .running {
            Button("Stop") { Task { await store.stopContainer(id: container.id) } }
            Button("Restart") { Task { await store.restartContainer(id: container.id) } }
        } else {
            Button("Start") { Task { await store.startContainer(id: container.id) } }
        }
        Divider()
        Button("Delete", role: .destructive) {
            Task { await store.deleteContainer(id: container.id, force: false) }
        }
    }
}
