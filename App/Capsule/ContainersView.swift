import AppCore
import ContainerClient
import SwiftUI
import TerminalKit

struct ContainersView: View {
    let session: RuntimeSession

    @State private var detailStore: ContainerDetailStore?
    @State private var terminalManager: TerminalSessionManager?
    @State private var metricsStore: ContainerMetricsStore?
    @State private var systemStore: SystemStore?
    @State private var selection: String?
    @State private var isStartingRuntime = false
    @AppStorage("containerCollectionMode") private var collectionMode = CapsuleCollectionMode.cards

    init(session: RuntimeSession) {
        self.session = session
        _detailStore = State(initialValue: session.makeDetailStore())
        _terminalManager = State(initialValue: session.makeTerminalSessionManager())
        _metricsStore = State(initialValue: session.makeContainerMetricsStore())
        _systemStore = State(initialValue: session.makeSystemStore())
    }

    private var runningContainerIDs: [String] {
        session.containers.currentContainers
            .filter { $0.runState == .running }
            .map(\.id)
            .sorted()
    }

    var body: some View {
        listContent
            .navigationTitle("Containers")
            .toolbar {
                CapsuleCollectionModePicker(selection: $collectionMode)
            }
            .inspector(isPresented: inspectorPresented) {
                if let detailStore {
                    ContainerInspector(store: detailStore, terminalManager: terminalManager)
                }
            }
            .alert(
                "Container Action Failed",
                isPresented: Binding(
                    get: { session.containers.lastActionError != nil },
                    set: { if !$0 { session.containers.dismissActionError() } }
                )
            ) {
                Button("OK") { session.containers.dismissActionError() }
            } message: {
                Text(session.containers.lastActionError?.message ?? "Unknown error")
            }
            .task(id: runningContainerIDs) {
                await metricsStore?.observe(ids: runningContainerIDs)
            }
            .onChange(of: selection) { _, newValue in
                Task {
                    if let newValue {
                        await detailStore?.activate(id: newValue)
                    } else {
                        detailStore?.deactivate()
                    }
                }
            }
    }

    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { selection != nil },
            set: { isPresented in if !isPresented { selection = nil } }
        )
    }

    @ViewBuilder
    private var listContent: some View {
        switch session.containers.phase {
        case .connecting:
            ProgressView("Connecting…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .runtimeMissing(let message):
            ContentUnavailableView {
                Label("Runtime Not Found", systemImage: "shippingbox")
            } description: {
                Text(message)
            }
        case .unavailable(let message, let lastKnown):
            runtimeUnavailable(message: message, lastKnown: lastKnown)
        case .loaded(let containers) where containers.isEmpty:
            ContentUnavailableView {
                Label("No Containers", systemImage: "shippingbox")
            } description: {
                Text("Start a Compose project or run a container from the command line. It will appear here live.")
            }
        case .loaded(let containers):
            containerCollection(containers)
        }
    }

    @ViewBuilder
    private func runtimeUnavailable(message: String, lastKnown: [ContainerSummary]) -> some View {
        if lastKnown.isEmpty {
            VStack(spacing: 18) {
                ContentUnavailableView {
                    Label("Runtime Service Unavailable", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(Color(nsColor: .systemRed))
                } description: {
                    Text("Apple's container service is not responding. It may be stopped; start it to reconnect Capsule.")
                } actions: {
                    startRuntimeButton
                }

                runtimeFailureDetails(message)
                    .frame(maxWidth: 680)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Label("Runtime Service Unavailable", systemImage: "xmark.octagon.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Color(nsColor: .systemRed))
                        Text("Showing the last known container state.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        startRuntimeButton
                    }
                    runtimeFailureDetails(message)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .systemRed).opacity(0.1))

                containerCollection(lastKnown)
                    .disabled(true)
                    .opacity(0.58)
            }
        }
    }

    private var startRuntimeButton: some View {
        Button(action: startRuntime) {
            HStack(spacing: 7) {
                if isStartingRuntime {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "play.fill")
                }
                Text(isStartingRuntime ? "Starting…" : "Start Runtime")
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(CapsulePalette.accent)
        .disabled(systemStore == nil || isStartingRuntime)
        .accessibilityInputLabels(["Start Runtime"])
    }

    private func startRuntime() {
        guard let systemStore else { return }
        isStartingRuntime = true
        Task {
            await systemStore.startRuntime()
            isStartingRuntime = false
        }
    }

    private func runtimeFailureDetails(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup("Technical details") {
                Text(message)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)

            if let actionError = systemStore?.lastActionError {
                Label(actionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemRed))
            }
        }
    }

    private func containerCollection(_ containers: [ContainerSummary]) -> some View {
        VStack(spacing: 0) {
            collectionHeader(containers)
            Divider()
            ScrollView {
                switch collectionMode {
                case .cards:
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 280, maximum: 410), spacing: 12)],
                        alignment: .leading,
                        spacing: 12
                    ) {
                        ForEach(containers) { container in
                            containerSurface(container, layout: .card)
                        }
                    }
                case .list:
                    LazyVStack(spacing: 6) {
                        ForEach(containers) { container in
                            containerSurface(container, layout: .row)
                        }
                    }
                }
            }
            .contentMargins(18, for: .scrollContent)
        }
    }

    private func collectionHeader(_ containers: [ContainerSummary]) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Container fleet")
                    .font(.title3.weight(.semibold))
                Text("Select a container to inspect logs, processes, resources, and terminal access.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(
                "\(containers.count(where: { $0.runState == .running })) running",
                systemImage: "circle.fill"
            )
            .foregroundStyle(Color(nsColor: .systemGreen))
            Label(
                CapsuleFormatting.bytes(metricsStore?.totalMemoryUsageBytes ?? 0),
                systemImage: "memorychip"
            )
            .help("Total measured memory for running containers")
        }
        .font(.callout)
        .padding(.horizontal, 18)
        .frame(minHeight: 64)
    }

    private func containerSurface(
        _ container: ContainerSummary,
        layout: CapsuleResourceSurfaceLayout
    ) -> some View {
        ContainerRow(
            container: container,
            store: session.containers,
            layout: layout,
            isSelected: selection == container.id,
            sample: metricsStore?.sample(for: container.id),
            select: { selection = container.id }
        )
    }
}
