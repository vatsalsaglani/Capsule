import AppCore
import ContainerClient
import SwiftUI

/// The System screen (P1B B5) — runtime status/version, `system df` storage
/// usage, start/stop runtime, and an informational (never-shelled) DNS
/// sudo-command row. DNS domain listing and a log viewer are **not** on the
/// frozen `ContainerRuntime` contract yet (rule 10, AGENTS.md) — honestly
/// deferred, never faked. Runtime install/onboarding is P1D's boundary, not
/// built here.
struct SystemView: View {
    let session: RuntimeSession

    @State private var store: SystemStore?

    init(session: RuntimeSession) {
        self.session = session
        _store = State(initialValue: session.makeSystemStore())
    }

    var body: some View {
        Group {
            if let store {
                content(store: store)
            } else {
                ContentUnavailableView {
                    Label("Runtime Not Found", systemImage: "gearshape.2")
                } description: {
                    Text(runtimeMissingMessage)
                }
            }
        }
        .navigationTitle("System")
        .task {
            await store?.refresh()
        }
    }

    private var runtimeMissingMessage: String {
        if case .runtimeMissing(let message) = session.containers.phase {
            return message
        }
        return "The container runtime couldn't be reached."
    }

    @ViewBuilder
    private func content(store: SystemStore) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch store.phase {
                case .loading:
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't Load System Status", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    }
                case .loaded(let status, let diskUsage):
                    statusSection(status, store: store)
                    diskUsageSection(diskUsage)
                    dnsGuidanceSection
                    deferredFeaturesNote
                }
            }
            .padding()
        }
    }

    // MARK: - Status

    private func statusSection(_ status: SystemStatus, store: SystemStore) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // Runtime up/down goes through the one state-color mapping
                // (`ContainerStateColor`) — accent indigo never means state
                // (§6.7 rule 1); "running"/"stopped" already cover the two
                // cases this dot needs.
                Circle()
                    .fill(ContainerStateColor.color(for: status.isRunning ? "running" : "stopped"))
                    .frame(width: 10, height: 10)
                Text(status.status.capitalized)
                    .font(.title3.weight(.semibold))
                Spacer()
                if status.isRunning {
                    Button("Stop Runtime") { Task { await store.stopRuntime() } }
                } else {
                    Button("Start Runtime") { Task { await store.startRuntime() } }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Runtime — \(status.status)")

            if let version = status.apiServerVersion {
                labeledRow("API Server Version", value: version)
            }
            if let build = status.apiServerBuild {
                labeledRow("Build", value: build)
            }
            if let commit = status.apiServerCommit {
                labeledRow("Commit", value: commit)
            }
            if let error = store.lastActionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemRed))
            }
        }
    }

    private func labeledRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout.monospaced())
        }
    }

    // MARK: - Disk usage

    private func diskUsageSection(_ diskUsage: SystemDiskUsage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Disk Usage").font(.headline)
            usageRow("Containers", usage: diskUsage.containers)
            usageRow("Images", usage: diskUsage.images)
            usageRow("Volumes", usage: diskUsage.volumes)
        }
    }

    private func usageRow(_ label: String, usage: ResourceUsage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.callout.weight(.medium))
                Spacer()
                Text("\(usage.active)/\(usage.total) active")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            // Bar is real reclaimable-of-total proportion, not a fabricated
            // capacity gauge (rule 10, AGENTS.md — no invented data). Orange
            // segment mirrors the same warning use already established for
            // the Containers screen's "unavailable" banner, not container
            // run-state.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.accentColor.opacity(0.25))
                    Capsule()
                        .fill(Color(nsColor: .systemOrange))
                        .frame(width: geometry.size.width * reclaimableFraction(usage))
                }
            }
            .frame(height: 6)
            // The fill's proportion is neutral data-viz, not container state
            // (accent here is the track, orange the reclaimable amount) —
            // still needs a value label since color/position alone carry no
            // VoiceOver signal (§6.5).
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label) disk usage")
            .accessibilityValue(diskUsageAccessibilityValue(usage))
            HStack(spacing: 4) {
                Text(byteCountDescription(usage.sizeInBytes))
                    .font(.caption.monospacedDigit())
                if usage.reclaimableBytes > 0 {
                    Text("· \(byteCountDescription(usage.reclaimableBytes)) reclaimable")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func reclaimableFraction(_ usage: ResourceUsage) -> CGFloat {
        guard usage.sizeInBytes > 0 else { return 0 }
        return CGFloat(Double(usage.reclaimableBytes) / Double(usage.sizeInBytes))
    }

    private func diskUsageAccessibilityValue(_ usage: ResourceUsage) -> String {
        let percent = Int((reclaimableFraction(usage) * 100).rounded())
        return "\(byteCountDescription(usage.sizeInBytes)) total, \(percent) percent reclaimable"
    }

    private func byteCountDescription(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    // MARK: - DNS guidance

    /// Sudo-required ops never get shelled from the app (plan §3) — this is
    /// a copy-command flow only, never executed. See spike S1 for why
    /// search-domain DNS still needs one-time host setup.
    private var dnsGuidanceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DNS Setup").font(.headline)
            Text("Capsule never runs sudo commands itself. To enable search-domain DNS for container-to-container name resolution, paste this into Terminal:")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(Self.dnsCommand)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                Spacer()
                Button("Copy Command", systemImage: "doc.on.doc") {
                    copyToPasteboard(Self.dnsCommand)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Copy command")
            }
        }
    }

    private static let dnsCommand = "sudo container system dns create capsule"

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Honest scoping (rule 10, AGENTS.md) — DNS domain listing and a
    /// system-log viewer aren't in `ContainerRuntime`'s frozen surface yet.
    private var deferredFeaturesNote: some View {
        Text("DNS domain listing and the system log viewer aren't available on the current runtime surface yet.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
