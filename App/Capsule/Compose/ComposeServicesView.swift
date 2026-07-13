import AppCore
import ComposeRuntime
import ContainerClient
import SwiftUI

struct ComposeServicesView: View {
    let services: [ComposeServiceStatus]
    let metrics: ContainerMetricsStore?
    let supervision: ProjectSupervisionSnapshot?
    @Binding var mode: CapsuleCollectionMode
    @Binding var selection: String?

    private let columns = [GridItem(.adaptive(minimum: 270, maximum: 390), spacing: 12)]

    private var supervisionByService: [String: ServiceSupervisionSnapshot] {
        Dictionary(uniqueKeysWithValues: (supervision?.services ?? []).map { ($0.id, $0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Services")
                        .font(.title3.weight(.semibold))
                    Text("\(runningCount) running of \(services.count)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                CapsuleCollectionModePicker(selection: $mode)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            if services.isEmpty {
                ContentUnavailableView("No Services", systemImage: "square.stack.3d.up")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    switch mode {
                    case .cards:
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(services) { service in
                                serviceSurface(service, layout: .card)
                            }
                        }
                    case .list:
                        LazyVStack(spacing: 6) {
                            ForEach(services) { service in
                                serviceSurface(service, layout: .row)
                            }
                        }
                    }
                }
                .contentMargins(18, for: .scrollContent)
            }
        }
        .inspector(isPresented: inspectorPresented) {
            if let selectedService {
                ComposeServiceInspector(
                    service: selectedService,
                    sample: sample(for: selectedService),
                    supervision: supervisionByService[selectedService.id]
                )
            }
        }
    }

    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { selectedService != nil },
            set: { if !$0 { selection = nil } }
        )
    }

    private var selectedService: ComposeServiceStatus? {
        services.first { $0.id == selection }
    }

    private var runningCount: Int {
        services.count(where: { $0.runtimeState == .running })
    }

    private func sample(for service: ComposeServiceStatus) -> StatsSample? {
        guard let id = service.containerID else { return nil }
        return metrics?.sample(for: id)
    }

    private func serviceSurface(
        _ service: ComposeServiceStatus,
        layout: CapsuleResourceSurfaceLayout
    ) -> some View {
        CapsuleResourceSurface(
            layout: layout,
            isSelected: selection == service.id,
            accessibilityLabel: "\(service.service), \(service.runtimeState.rawValue)",
            select: { selection = service.id }
        ) {
            ComposeServiceSummary(
                service: service,
                sample: sample(for: service),
                supervision: supervisionByService[service.id],
                compact: layout == .row
            )
        } actions: {
            Button("Inspect", systemImage: "sidebar.right") { selection = service.id }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Inspect \(service.service)")
        }
    }
}

private struct ComposeServiceSummary: View {
    let service: ComposeServiceStatus
    let sample: StatsSample?
    let supervision: ServiceSupervisionSnapshot?
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 10) {
            HStack(spacing: 8) {
                ContainerStateDot(status: service.runtimeState.rawValue)
                Text(service.service)
                    .font(.headline)
                    .lineLimit(1)
                if let health = supervision?.health {
                    CapsuleBadge(
                        health.isLive ? health.state.rawValue.capitalized : "\(health.state.rawValue.capitalized) · stale",
                        systemImage: health.isLive ? "heart.fill" : "clock",
                        color: healthColor(health.state.rawValue)
                    )
                } else if let health = service.health {
                    CapsuleBadge(health.rawValue.capitalized, color: healthColor(health.rawValue))
                }
                if supervision?.restart.scheduledFor != nil {
                    CapsuleBadge("Restart queued", systemImage: "arrow.clockwise", color: Color(nsColor: .systemOrange))
                }
                Spacer()
                Text(service.runtimeState.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ContainerStateColor.color(for: service.runtimeState.rawValue))
            }
            Text(service.containerID ?? "Not created")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if supervision?.restart.limitation == .exitStatusUnavailable {
                Label("on-failure paused: exit status unavailable", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .lineLimit(1)
            }
            if compact {
                HStack {
                    Text(portsSummary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let sample {
                        Text(CapsuleFormatting.bytes(sample.memoryUsageBytes))
                            .font(.caption.monospacedDigit().weight(.medium))
                    }
                }
            } else {
                if !service.ports.isEmpty {
                    Label(portsSummary, systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let sample {
                    CapsuleMetricView(
                        title: "Memory",
                        value: CapsuleFormatting.memory(sample.memoryUsageBytes, limit: sample.memoryLimitBytes),
                        fraction: CapsuleFormatting.fraction(sample.memoryUsageBytes, of: sample.memoryLimitBytes)
                    )
                }
            }
        }
    }

    private var portsSummary: String {
        if service.ports.isEmpty { return "No published ports" }
        return service.ports.map { "\($0.hostPort)→\($0.containerPort)" }.joined(separator: ", ")
    }

    private func healthColor(_ health: String) -> Color {
        switch health {
        case "healthy": Color(nsColor: .systemGreen)
        case "starting": Color(nsColor: .systemOrange)
        case "unhealthy": Color(nsColor: .systemRed)
        default: .secondary
        }
    }
}

private struct ComposeServiceInspector: View {
    let service: ComposeServiceStatus
    let sample: StatsSample?
    let supervision: ServiceSupervisionSnapshot?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    ContainerStateDot(status: service.runtimeState.rawValue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.service).font(.title3.weight(.semibold))
                        Text(service.runtimeState.rawValue.capitalized)
                            .foregroundStyle(ContainerStateColor.color(for: service.runtimeState.rawValue))
                    }
                }
                inspectorSection("Container") {
                    Text(service.containerID ?? "Not created")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                inspectorSection("Health") {
                    if let health = supervision?.health {
                        HStack(spacing: 7) {
                            CapsuleBadge(
                                health.state.rawValue.capitalized,
                                systemImage: health.isLive ? "heart.fill" : "clock",
                                color: healthColor(health.state.rawValue)
                            )
                            Text(health.isLive ? "Live observation" : "Restored; waiting for a live probe")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(health.output.isEmpty ? "No probe output" : health.output)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("Attempt \(health.attempt) · \(health.observedAt, format: .relative(presentation: .named))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(service.health == nil ? "No healthcheck configured" : service.health?.rawValue.capitalized ?? "Unknown")
                            .foregroundStyle(.secondary)
                    }
                }
                inspectorSection("Restart supervision") {
                    if let restart = supervision?.restart {
                        Text(restartPolicyTitle(restart))
                            .font(.callout.weight(.medium))
                        Text("\(restart.attempts) supervised restart \(restart.attempts == 1 ? "attempt" : "attempts")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let scheduledFor = restart.scheduledFor {
                            Label(
                                "Retry \(scheduledFor, format: .relative(presentation: .named))",
                                systemImage: "clock.arrow.circlepath"
                            )
                            .font(.caption)
                            .foregroundStyle(Color(nsColor: .systemOrange))
                        }
                        if restart.limitation == .exitStatusUnavailable {
                            Label(
                                "Exact on-failure behavior is unavailable on container 1.1.x because stopped containers expose no exit status.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.caption)
                            .foregroundStyle(Color(nsColor: .systemOrange))
                        }
                        if let lastError = restart.lastError {
                            Text(lastError)
                                .font(.caption.monospaced())
                                .foregroundStyle(Color(nsColor: .systemRed))
                                .textSelection(.enabled)
                        }
                    } else {
                        Text("Waiting for resident supervision")
                            .foregroundStyle(.secondary)
                    }
                }
                inspectorSection("Ports") {
                    if service.ports.isEmpty {
                        Text("No published ports").foregroundStyle(.secondary)
                    } else {
                        ForEach(service.ports, id: \.self) { port in
                            Text("\(port.hostPort) → \(port.containerPort)/\(port.proto.rawValue)")
                                .font(.callout.monospacedDigit())
                        }
                    }
                }
                inspectorSection("Resources") {
                    if let sample {
                        CapsuleMetricView(
                            title: "Memory",
                            value: CapsuleFormatting.memory(sample.memoryUsageBytes, limit: sample.memoryLimitBytes),
                            fraction: CapsuleFormatting.fraction(sample.memoryUsageBytes, of: sample.memoryLimitBytes)
                        )
                        Text("\(sample.processCount) processes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(service.runtimeState == .running ? "Collecting metrics…" : "Metrics are available while running")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
        }
        .inspectorColumnWidth(min: 260, ideal: 310, max: 420)
    }

    private func inspectorSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func healthColor(_ health: String) -> Color {
        switch health {
        case "healthy": Color(nsColor: .systemGreen)
        case "starting": Color(nsColor: .systemOrange)
        case "unhealthy": Color(nsColor: .systemRed)
        default: .secondary
        }
    }

    private func restartPolicyTitle(_ restart: ServiceRestartSnapshot) -> String {
        switch restart.policy {
        case .never: "Restart policy: no"
        case .always: "Restart policy: always"
        case .unlessStopped: "Restart policy: unless-stopped"
        case .onFailure(let maxRetries):
            maxRetries.map { "Restart policy: on-failure:\($0)" }
                ?? "Restart policy: on-failure"
        }
    }
}
