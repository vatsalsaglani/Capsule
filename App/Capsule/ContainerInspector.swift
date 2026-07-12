import AppCore
import Charts
import ContainerClient
import SwiftUI

/// The trailing inspector panel — image/digest, addresses, published ports
/// (with open-in-browser), labels, mounts, logs (follow, solid-dark), and a
/// CPU sparkline (visibility-gated per S4 discipline). Shared between the
/// real Containers screen and the `#if DEBUG` feel prototype.
struct ContainerInspector: View {
    let store: ContainerDetailStore

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedTab: Tab = .overview

    private enum Tab: Hashable {
        case overview, logs, stats
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Picker("Section", selection: $selectedTab) {
                Text("Overview").tag(Tab.overview)
                Text("Logs").tag(Tab.logs)
                Text("Stats").tag(Tab.stats)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 8)

            Group {
                switch selectedTab {
                case .overview: overviewTab
                case .logs: logsTab
                case .stats: statsTab
                }
            }
            // Interruptible, state-driven transition (§6.3) rather than a
            // hard swap; cross-fade under reduced motion (§6.5).
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
            .animation(CapsuleMotion.standard, value: selectedTab)
        }
        .onChange(of: selectedTab) { _, newValue in
            store.setStatsVisible(newValue == .stats)
        }
        .onDisappear {
            store.setStatsVisible(false)
        }
        .inspectorColumnWidth(min: 280, ideal: 340, max: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(store.currentID ?? "")
                .font(.title3.weight(.semibold))
            if let detail = store.detail {
                Text(detail.status.capitalized)
                    .font(.callout)
                    .foregroundStyle(ContainerStateColor.color(for: detail.status))
            }
        }
        .padding([.horizontal, .top])
        // Color alone never carries the state signal (§6.5) — the combined
        // label pairs the id with the status text already rendered above.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headerAccessibilityLabel)
    }

    private var headerAccessibilityLabel: String {
        guard let detail = store.detail else { return store.currentID ?? "" }
        return "\(store.currentID ?? "") — \(detail.status)"
    }

    // MARK: - Overview

    private var overviewTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let detail = store.detail {
                    imageSection(detail)
                    addressesSection(detail)
                    portsSection(detail)
                    labelsSection(detail)
                    mountsSection(detail)
                    deferredFeaturesNote
                } else if let detailError = store.detailError {
                    ContentUnavailableView {
                        Label("Couldn't Load", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(detailError)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                }
            }
            .padding()
        }
    }

    private func imageSection(_ detail: ContainerDetail) -> some View {
        labeledSection("Image") {
            Text(detail.imageReference ?? "unknown")
                .font(.callout.monospaced())
            if let digest = detail.imageDigest {
                Text(digest)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func addressesSection(_ detail: ContainerDetail) -> some View {
        let addresses = detail.networks.compactMap(\.ipAddress)
        return labeledSection("Addresses") {
            if addresses.isEmpty {
                Text("No addresses").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(addresses, id: \.self) { address in
                    Text(address).font(.callout.monospacedDigit())
                }
            }
        }
    }

    private func portsSection(_ detail: ContainerDetail) -> some View {
        labeledSection("Ports") {
            if detail.ports.isEmpty {
                Text("No published ports").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(detail.ports.enumerated()), id: \.offset) { _, port in
                    HStack {
                        Text("\(port.hostPort) → \(port.containerPort)/\(port.proto.rawValue)")
                            .font(.callout.monospacedDigit())
                        Spacer()
                        if let url = store.browserURL(for: port) {
                            Button("Open in Browser", systemImage: "safari") {
                                openURL(url)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Open \(url.absoluteString)")
                        }
                    }
                }
            }
        }
    }

    private func labelsSection(_ detail: ContainerDetail) -> some View {
        labeledSection("Labels") {
            if detail.labels.isEmpty {
                Text("No labels").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(detail.labels.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    Text("\(key) = \(value)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func mountsSection(_ detail: ContainerDetail) -> some View {
        labeledSection("Mounts") {
            if detail.mounts.isEmpty {
                Text("No mounts").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(detail.mounts.enumerated()), id: \.offset) { _, mount in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mount.destination).font(.callout.monospaced())
                        if let source = mount.source {
                            Text(source + (mount.isReadOnly ? "  (read-only)" : ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// Honest scoping (rule 10, AGENTS.md) — no fake buttons for features the
    /// runtime contract doesn't support yet: env isn't on `ContainerDetail`
    /// (unverified shape) and `container cp` isn't in `ContainerRuntime`.
    private var deferredFeaturesNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Environment variables aren't available from the runtime yet.")
            Text("File copy is coming with a later runtime update.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func labeledSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Logs

    private var logsTab: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(store.logLines.enumerated()), id: \.offset) { index, line in
                        Text(line.text)
                            .font(.system(.caption, design: .monospaced))
                            // #EBEBF0 on #161618 — always-dark log surface,
                            // both appearance modes (plan §6.7).
                            .foregroundStyle(Color(red: 0.92, green: 0.92, blue: 0.94))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(8)
            }
            // Solid dark, never translucent — logs/terminal surfaces are the
            // one exception to the sidebar/content material rules (§6.2).
            .background(Color(red: 0.086, green: 0.086, blue: 0.094))
            .onChange(of: store.logLines.count) { _, _ in
                guard let lastIndex = store.logLines.indices.last else { return }
                proxy.scrollTo(lastIndex, anchor: .bottom)
            }
        }
    }

    // MARK: - Stats

    private var statsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.cpuPercentSeries.isEmpty {
                ContentUnavailableView("Collecting Stats…", systemImage: "waveform.path.ecg")
            } else {
                cpuChart
                if let latest = store.statsSeries.last {
                    memorySection(latest)
                }
            }
        }
        .padding()
    }

    private var cpuChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CPU").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Chart(store.cpuPercentSeries) { point in
                LineMark(x: .value("Time", point.at), y: .value("CPU %", point.percent))
                    .interpolationMethod(.monotone)
                    .accessibilityLabel("CPU")
                    .accessibilityValue("\(Int(point.percent)) percent")
            }
            .chartYScale(domain: 0...max(100, (store.cpuPercentSeries.map(\.percent).max() ?? 100)))
            .chartXAxis(.hidden)
            .frame(minHeight: 120, maxHeight: 160)
            // Swift Charts animates new points drawing onto the line by
            // default — gate that under reduced motion (§6.5) the same way
            // the tab transition and state-dot pulse already do; the sample
            // still lands instantly, just without the animated draw-in.
            .animation(reduceMotion ? nil : .default, value: store.cpuPercentSeries)
        }
    }

    private func memorySection(_ point: StatsPoint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Memory").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(memoryDescription(point.sample))
                .font(.callout.monospacedDigit())
        }
    }

    private func memoryDescription(_ sample: StatsSample) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        let used = formatter.string(fromByteCount: Int64(sample.memoryUsageBytes))
        let limit = formatter.string(fromByteCount: Int64(sample.memoryLimitBytes))
        return "\(used) / \(limit)"
    }
}
