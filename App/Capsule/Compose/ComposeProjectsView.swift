import AppCore
import ComposeRuntime
import ContainerClient
import SwiftUI
import Supervisor
import UniformTypeIdentifiers

struct ComposeProjectsView: View {
    let session: RuntimeSession
    @State private var store: ComposeProjectsStore?
    @State private var selection: ComposeProjectItem?
    @State private var detailStore: ComposeProjectDetailStore?
    @State private var metricsStore: ContainerMetricsStore?
    @State private var showingImporter = false
    @State private var importError: String?

    init(session: RuntimeSession) {
        self.session = session
        _store = State(initialValue: session.makeComposeProjectsStore())
        _metricsStore = State(initialValue: session.makeContainerMetricsStore())
    }

    var body: some View {
        Group {
            if let store {
                HSplitView {
                    projectNavigator(store)
                        .frame(minWidth: 210, idealWidth: 245, maxWidth: 310)
                    if let detailStore {
                        ComposeProjectDetailView(store: detailStore, metricsStore: metricsStore)
                            .id(detailStore.item.id)
                            .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        dropTarget
                            .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                ContentUnavailableView("Runtime unavailable", systemImage: "square.stack.3d.up")
            }
        }
        .navigationTitle("Compose Projects")
        .toolbar {
            Button {
                showingImporter = true
            } label: {
                Label("Import Compose File", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(CapsulePalette.accent)
            .disabled(store == nil)
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.yaml, .text],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else {
                if case .failure(let error) = result { importError = error.localizedDescription }
                return
            }
            importFile(url)
        }
        .alert(
            "Couldn't Import Project",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )
        ) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "Unknown error")
        }
        .task {
            await store?.refresh()
            selectFirstProjectIfNeeded()
        }
    }

    @ViewBuilder
    private func projectNavigator(_ store: ComposeProjectsStore) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Projects")
                    .font(.headline)
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task {
                        await store.refresh()
                        selectFirstProjectIfNeeded()
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Refresh projects")
            }
            .padding(.horizontal, 12)
            .frame(height: 42)

            Divider()

            switch store.phase {
            case .loading:
                ProgressView("Loading projects…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView(
                    "Couldn't Load Projects",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            case .loaded(let projects):
                VStack(spacing: 0) {
                    if let warning = store.discoveryWarning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(Color(nsColor: .systemOrange))
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .systemOrange).opacity(0.08))
                    }

                    if projects.isEmpty {
                        ContentUnavailableView {
                            Label("No Compose Projects", systemImage: "square.stack.3d.up")
                        } description: {
                            Text("Import a Compose YAML file to create a project workspace.")
                        } actions: {
                            Button("Import Compose File") { showingImporter = true }
                                .buttonStyle(.borderedProminent)
                                .tint(CapsulePalette.accent)
                        }
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(projects) { project in
                                    projectRow(project)
                                }
                            }
                            .padding(8)
                        }
                    }
                }
            }
        }
        .background(CapsulePalette.background)
    }

    private func projectRow(_ project: ComposeProjectItem) -> some View {
        CapsuleResourceSurface(
            layout: .row,
            isSelected: selection?.id == project.id,
            accessibilityLabel: "Compose project (project.name)",
            select: { select(project) }
        ) {
            HStack(spacing: 9) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(selection?.id == project.id ? CapsulePalette.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(project.sourceAvailable ? "Compose source connected" : "Source unavailable")
                        .font(.caption)
                        .foregroundStyle(project.sourceAvailable ? .secondary : Color(nsColor: .systemOrange))
                        .lineLimit(1)
                }
            }
        } actions: {
            if project.sourceUnavailableDescription != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .help(project.sourceUnavailableDescription ?? "Compose source unavailable")
            }
        }
    }

    private var dropTarget: some View {
        ContentUnavailableView {
            Label("Select or Import a Project", systemImage: "square.and.arrow.down")
        } description: {
            Text("Drop a Compose YAML file here, or use Import Compose File.")
        } actions: {
            Button("Import Compose File") { showingImporter = true }
                .buttonStyle(.borderedProminent)
                .tint(CapsulePalette.accent)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            importFile(url)
            return true
        }
    }

    private func select(_ project: ComposeProjectItem) {
        guard selection?.id != project.id else { return }
        selection = project
        detailStore = store?.makeDetailStore(for: project)
    }

    private func selectFirstProjectIfNeeded() {
        guard selection == nil,
              let store,
              case .loaded(let projects) = store.phase,
              let project = projects.first else { return }
        select(project)
    }

    private func importFile(_ url: URL) {
        Task {
            do {
                guard let store else { return }
                let item = try await store.importFile(url)
                select(item)
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

private struct ComposeProjectDetailView: View {
    let store: ComposeProjectDetailStore
    let metricsStore: ContainerMetricsStore?

    @AppStorage("composeServiceCollectionMode") private var serviceMode = CapsuleCollectionMode.cards
    @State private var tab = Tab.services
    @State private var selectedService: String?
    @State private var showingPlan = false
    @State private var showingDown = false

    private var runningContainerIDs: [String] {
        store.services.compactMap { service in
            service.runtimeState == .running ? service.containerID : nil
        }.sorted()
    }

    private var runningCount: Int {
        store.services.count(where: { $0.runtimeState == .running })
    }

    var body: some View {
        VStack(spacing: 0) {
            projectHeader
            Divider()
            tabBar
            if let drift = store.supervision?.drift ?? store.drift,
               !drift.isInSync || !(store.supervision?.notices.isEmpty ?? true) {
                ComposeSupervisionBanner(
                    drift: drift,
                    notices: store.supervision?.notices ?? [],
                    isOperating: store.isOperating,
                    refresh: { Task { await store.reconcile(heal: false) } },
                    heal: { Task { await store.reconcile(heal: true) } }
                )
            }
            Group {
                switch store.phase {
                case .loading:
                    ProgressView("Resolving project…")
                case .failed(let message):
                    ContentUnavailableView(
                        "Project Error",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                case .loaded:
                    detailContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !store.operationLines.isEmpty {
                operationActivity
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(CapsulePalette.background)
        .sheet(isPresented: $showingPlan) { planSheet }
        .sheet(isPresented: $showingDown) {
            if let preview = store.downPreview {
                ComposeDownSheet(projectName: store.item.name, preview: preview) { removeVolumes in
                    Task { await store.down(removeVolumes: removeVolumes) }
                }
            }
        }
        .alert(
            "Compose Operation Failed",
            isPresented: Binding(
                get: { store.operationError != nil },
                set: { if !$0 { store.dismissOperationError() } }
            )
        ) {
            Button("OK") { store.dismissOperationError() }
        } message: {
            Text(store.operationError ?? "Unknown error")
        }
        .task(id: store.item.id) { await store.load() }
        .task(id: runningContainerIDs) {
            await metricsStore?.observe(ids: runningContainerIDs)
        }
        .onChange(of: tab) { _, newTab in
            if newTab == .logs { store.startLogs() } else { store.stopLogs() }
        }
        .onDisappear { store.stopLogs() }
    }

    private var projectHeader: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .foregroundStyle(CapsulePalette.accent)
                    Text(store.item.name)
                        .font(.title2.weight(.semibold))
                }
                HStack(spacing: 12) {
                    Label("\(runningCount)/\(store.services.count) running", systemImage: "circle.fill")
                        .foregroundStyle(runningCount > 0 ? Color(nsColor: .systemGreen) : .secondary)
                    Label(
                        CapsuleFormatting.bytes(metricsStore?.totalMemoryUsageBytes ?? 0),
                        systemImage: "memorychip"
                    )
                    if let sourceIssue = store.item.sourceUnavailableDescription {
                        Label(sourceIssue, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color(nsColor: .systemOrange))
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if store.isOperating {
                ProgressView()
                    .controlSize(.small)
                    .help("Compose operation in progress")
            }

            Button("Restart", systemImage: "arrow.clockwise") {
                Task { await store.restart() }
            }
            .disabled(!store.canOperate || store.isOperating)

            Button("Down", systemImage: "stop.fill") {
                Task {
                    if await store.prepareDownPreview() { showingDown = true }
                }
            }
            .disabled(!store.canOperate || store.isOperating)

            Button("Up", systemImage: "play.fill") {
                Task {
                    if await store.prepareUp() { showingPlan = true }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(CapsulePalette.accent)
            .disabled(!store.canOperate || store.isOperating)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 70)
    }

    private var tabBar: some View {
        HStack {
            Picker("Project detail", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 400)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch tab {
        case .services:
            ComposeServicesView(
                services: store.services,
                metrics: metricsStore,
                supervision: store.supervision,
                mode: $serviceMode,
                selection: $selectedService
            )
        case .graph:
            if let graph = store.supervision?.dependencyGraph ?? store.dependencyGraph {
                ComposeDependencyGraphView(graph: graph, services: store.services)
            } else {
                ContentUnavailableView(
                    "Graph Unavailable",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Resolve this project to inspect its dependency start order.")
                )
            }
        case .logs:
            ComposeLogConsole(store: store)
        case .config:
            config
        }
    }

    private var config: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                configSection("Resolved Compose configuration", content: store.resolvedConfiguration)
                configSection("Compatibility report", content: store.configReport)
            }
            .frame(maxWidth: 960, alignment: .leading)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func configSection(_ title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            Text(content.isEmpty ? "No details available." : content)
                .font(.callout.monospaced())
                .foregroundStyle(content.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(CapsulePalette.surface, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(CapsulePalette.hairline))
    }

    private var operationActivity: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Label(store.isOperating ? "Compose activity" : "Last Compose activity", systemImage: "waveform.path.ecg")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Clear", systemImage: "xmark") { store.clearOperationLines() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(store.isOperating)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            ScrollView {
                Text(store.operationLines.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            .frame(minHeight: 64, maxHeight: 170)
        }
        .background(CapsulePalette.elevated.opacity(0.48))
    }

    private var planSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "list.bullet.clipboard.fill")
                    .font(.title2)
                    .foregroundStyle(CapsulePalette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Review Up Plan")
                        .font(.title2.weight(.semibold))
                    Text("Capsule will apply these steps to \(store.item.name).")
                        .foregroundStyle(.secondary)
                }
            }
            if !store.configReport.isEmpty {
                Text(store.configReport)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(store.planLines.joined(separator: "\n"))
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(CapsulePalette.surface, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(CapsulePalette.hairline))
            HStack {
                Spacer()
                Button("Cancel") { showingPlan = false }
                Button("Apply Plan") {
                    showingPlan = false
                    Task { await store.confirmUp() }
                }
                .buttonStyle(.borderedProminent)
                .tint(CapsulePalette.accent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(minWidth: 680, minHeight: 500)
    }

    private enum Tab: String, CaseIterable, Identifiable {
        case services
        case graph
        case logs
        case config

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }
}

private struct ComposeSupervisionBanner: View {
    let drift: DriftReport
    let notices: [SupervisionNotice]
    let isOperating: Bool
    let refresh: () -> Void
    let heal: () -> Void

    private var orphanCount: Int {
        drift.findings.count(where: { $0.kind == .orphan })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: drift.isInSync ? "checkmark.shield.fill" : "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                    .foregroundStyle(drift.isInSync
                                     ? Color(nsColor: .systemGreen)
                                     : Color(nsColor: .systemOrange))
                    .font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(drift.isInSync
                         ? "Supervision needs attention"
                         : "\(drift.findings.count) drift \(drift.findings.count == 1 ? "change" : "changes") detected")
                        .font(.callout.weight(.semibold))
                    if !drift.isInSync {
                        Text(drift.findings.map(\.message).joined(separator: "  "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if orphanCount > 0 {
                        Text("\(orphanCount) orphaned \(orphanCount == 1 ? "container is" : "containers are") report-only; removal stays behind Down → Remove orphans.")
                            .font(.caption)
                            .foregroundStyle(Color(nsColor: .systemOrange))
                    }
                    ForEach(notices) { notice in
                        Label(notice.message, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(Color(nsColor: .systemOrange))
                    }
                }
                Spacer(minLength: 12)
                Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                    .disabled(isOperating)
                if !drift.isInSync {
                    Button("Reconcile", systemImage: "wrench.and.screwdriver", action: heal)
                        .buttonStyle(.borderedProminent)
                        .tint(CapsulePalette.accent)
                        .disabled(isOperating)
                        .help("Recreate missing or changed services and restore their recorded running state")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Color(nsColor: .systemOrange).opacity(0.075))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Compose supervision status")
    }
}

private extension UTType {
    static let yaml = UTType(filenameExtension: "yaml") ?? .text
}
