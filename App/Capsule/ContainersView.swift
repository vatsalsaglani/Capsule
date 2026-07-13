import AppCore
import ContainerClient
import SwiftUI
import TerminalKit

struct ContainersView: View {
    let session: RuntimeSession

    @State private var detailStore: ContainerDetailStore?
    @State private var terminalManager: TerminalSessionManager?
    @State private var metricsStore: ContainerMetricsStore?
    @State private var selection: String?
    @AppStorage("containerCollectionMode") private var collectionMode = CapsuleCollectionMode.cards

    init(session: RuntimeSession) {
        self.session = session
        _detailStore = State(initialValue: session.makeDetailStore())
        _terminalManager = State(initialValue: session.makeTerminalSessionManager())
        _metricsStore = State(initialValue: session.makeContainerMetricsStore())
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
            VStack(spacing: 0) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .systemOrange).opacity(0.1))
                containerCollection(lastKnown)
                    .disabled(true)
                    .opacity(0.58)
            }
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
