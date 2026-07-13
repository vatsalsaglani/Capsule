import ComposeRuntime
import ContainerClient
import SwiftUI

/// The Phase 3 dependency showpiece: Canvas owns the relationship layer,
/// while native Buttons remain above it for pointer, keyboard, and VoiceOver
/// interaction.
struct ComposeDependencyGraphView: View {
    let graph: ComposeDependencyGraph
    let services: [ComposeServiceStatus]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedService: String?

    private var servicesByName: [String: ComposeServiceStatus] {
        Dictionary(uniqueKeysWithValues: services.map { ($0.service, $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dependency graph")
                        .font(.title3.weight(.semibold))
                    Text("Start order flows left to right. Select a service to trace its relationships.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                CapsuleBadge("\(graph.startLayers.count) layers", systemImage: "square.stack.3d.forward.dottedline")
            }

            if graph.services.isEmpty {
                ContentUnavailableView("No Services", systemImage: "point.3.connected.trianglepath.dotted")
                    .frame(maxWidth: .infinity, minHeight: 320)
            } else {
                GeometryReader { proxy in
                    let layout = ComposeGraphLayout(graph: graph, size: proxy.size)
                    ZStack {
                        ComposeDependencyEdges(
                            edges: graph.edges,
                            positions: layout.positions,
                            selectedService: selectedService
                        )
                        ForEach(graph.services, id: \.self) { service in
                            ComposeDependencyNode(
                                service: service,
                                status: servicesByName[service],
                                isSelected: selectedService == service,
                                select: { selectedService = service }
                            )
                            .position(layout.positions[service] ?? .zero)
                        }
                    }
                    .animation(
                        reduceMotion ? nil : CapsuleMotion.standard,
                        value: selectedService
                    )
                }
                .frame(minHeight: 360)
                .padding(12)
                .background(CapsulePalette.surface, in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(CapsulePalette.hairline))
            }

            if let selectedService {
                ComposeDependencySelection(
                    service: selectedService,
                    edges: graph.edges
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ComposeDependencyEdges: View {
    let edges: [ComposeDependencyGraph.Edge]
    let positions: [String: CGPoint]
    let selectedService: String?

    var body: some View {
        Canvas { context, _ in
            for edge in edges {
                guard let start = positions[edge.dependency],
                      let end = positions[edge.dependent]
                else { continue }
                let highlighted = selectedService == nil
                    || selectedService == edge.dependency
                    || selectedService == edge.dependent
                let startPoint = CGPoint(x: start.x + 78, y: start.y)
                let endPoint = CGPoint(x: end.x - 78, y: end.y)
                let controlOffset = max(28, (endPoint.x - startPoint.x) * 0.42)
                var path = Path()
                path.move(to: startPoint)
                path.addCurve(
                    to: endPoint,
                    control1: CGPoint(x: startPoint.x + controlOffset, y: startPoint.y),
                    control2: CGPoint(x: endPoint.x - controlOffset, y: endPoint.y)
                )
                context.stroke(
                    path,
                    with: .color(CapsulePalette.accent.opacity(highlighted ? 0.7 : 0.16)),
                    style: StrokeStyle(lineWidth: highlighted ? 2 : 1, lineCap: .round)
                )

                let angle = atan2(endPoint.y - startPoint.y, endPoint.x - startPoint.x)
                var arrow = Path()
                arrow.move(to: endPoint)
                arrow.addLine(to: CGPoint(
                    x: endPoint.x - 8 * cos(angle - .pi / 6),
                    y: endPoint.y - 8 * sin(angle - .pi / 6)
                ))
                arrow.move(to: endPoint)
                arrow.addLine(to: CGPoint(
                    x: endPoint.x - 8 * cos(angle + .pi / 6),
                    y: endPoint.y - 8 * sin(angle + .pi / 6)
                ))
                context.stroke(
                    arrow,
                    with: .color(CapsulePalette.accent.opacity(highlighted ? 0.78 : 0.16)),
                    style: StrokeStyle(lineWidth: highlighted ? 2 : 1, lineCap: .round)
                )
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ComposeDependencyNode: View {
    let service: String
    let status: ComposeServiceStatus?
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    ContainerStateDot(status: status?.runtimeState.rawValue ?? "unknown")
                    Text(service)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isSelected ? CapsulePalette.accent : CapsulePalette.secondary.opacity(0.7))
                }
                HStack(spacing: 6) {
                    Text(status?.runtimeState.rawValue.capitalized ?? "Not created")
                        .foregroundStyle(.secondary)
                    if let health = status?.health {
                        Text("• \(health.rawValue)")
                            .foregroundStyle(healthColor(health.rawValue))
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(width: 156, height: 62, alignment: .leading)
            .background(
                CapsulePalette.selectionFill(isSelected: isSelected, isHovered: isHovered),
                in: .rect(cornerRadius: 11)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .stroke(CapsulePalette.selectionStroke(isSelected: isSelected, isHovered: isHovered))
            )
        }
        .buttonStyle(CapsulePressButtonStyle())
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(service), \(status?.runtimeState.rawValue ?? "not created")")
        .accessibilityHint("Shows dependency relationships")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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

private struct ComposeDependencySelection: View {
    let service: String
    let edges: [ComposeDependencyGraph.Edge]

    private var incoming: [ComposeDependencyGraph.Edge] {
        edges.filter { $0.dependent == service }
    }

    private var outgoing: [ComposeDependencyGraph.Edge] {
        edges.filter { $0.dependency == service }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(service)
                .font(.headline)
            if incoming.isEmpty && outgoing.isEmpty {
                Text("This service starts independently and has no dependents.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(incoming) { edge in
                    Label(
                        "Waits for \(edge.dependency): \(condition(edge.condition.rawValue))",
                        systemImage: "arrow.down.left"
                    )
                }
                ForEach(outgoing) { edge in
                    Label(
                        "Unblocks \(edge.dependent): \(condition(edge.condition.rawValue))",
                        systemImage: "arrow.up.right"
                    )
                }
            }
        }
        .font(.callout)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CapsulePalette.accent.opacity(0.08), in: .rect(cornerRadius: 11))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Relationships for \(service)")
    }

    private func condition(_ value: String) -> String {
        switch value {
        case "service_started": "service started"
        case "service_healthy": "service healthy"
        case "service_completed_successfully": "service completed successfully"
        default: value.replacingOccurrences(of: "_", with: " ")
        }
    }
}

private struct ComposeGraphLayout {
    let positions: [String: CGPoint]

    init(graph: ComposeDependencyGraph, size: CGSize) {
        var layers = graph.startLayers.filter { !$0.isEmpty }
        let positioned = Set(layers.flatMap { $0 })
        let missing = graph.services.filter { !positioned.contains($0) }
        if !missing.isEmpty { layers.append(missing) }
        if layers.isEmpty { layers = [graph.services] }

        let horizontalPadding = min(100.0, max(82.0, size.width * 0.08))
        let verticalPadding = 52.0
        let usableWidth = max(0, size.width - horizontalPadding * 2)
        let usableHeight = max(0, size.height - verticalPadding * 2)
        var result: [String: CGPoint] = [:]
        for (layerIndex, services) in layers.enumerated() {
            let x = layers.count == 1
                ? size.width / 2
                : horizontalPadding + usableWidth * Double(layerIndex) / Double(layers.count - 1)
            for (rowIndex, service) in services.enumerated() {
                let y = services.count == 1
                    ? size.height / 2
                    : verticalPadding + usableHeight * Double(rowIndex) / Double(services.count - 1)
                result[service] = CGPoint(x: x, y: y)
            }
        }
        positions = result
    }
}
