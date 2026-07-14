import AppCore
import ContainerClient
import SwiftUI

struct MachinesView: View {
    let session: RuntimeSession

    @State private var store: MachinesStore?
    @State private var showingCreate = false
    @State private var pendingDelete: MachineSummary?
    @AppStorage("machineCollectionMode") private var collectionMode = CapsuleCollectionMode.cards

    init(session: RuntimeSession) {
        self.session = session
        _store = State(initialValue: session.makeMachinesStore())
    }

    var body: some View {
        content
            .navigationTitle("Machines")
            .toolbar {
                CapsuleCollectionModePicker(selection: $collectionMode)
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await store?.refresh() }
                }
                .help("Refresh machines")
                Button("Create Machine", systemImage: "plus") { showingCreate = true }
                    .buttonStyle(.borderedProminent)
                    .tint(CapsulePalette.accent)
            }
            .task { await store?.refresh() }
            .sheet(isPresented: $showingCreate) {
                if let store { CreateMachineSheet(store: store) }
            }
            .sheet(item: $pendingDelete) { machine in
                CapsuleDestructiveResourceSheet(
                    title: "Delete \(machine.id)?",
                    message: "The machine, its virtual disk, and machine-local state will be permanently deleted. Containers and images inside it will no longer be available.",
                    actionTitle: "Delete Machine",
                    groups: [
                        CapsuleResourcePreviewGroup(
                            "Machine",
                            systemImage: "desktopcomputer",
                            names: [machine.id],
                            note: "\(machine.cpus) CPUs · \(CapsuleFormatting.bytes(machine.memoryBytes)) memory"
                        ),
                        CapsuleResourcePreviewGroup(
                            "Machine data",
                            systemImage: "internaldrive",
                            names: [machine.diskSizeBytes.map { CapsuleFormatting.bytes($0, style: .file) } ?? "Virtual disk"],
                            note: "The runtime does not expose an inventory of data stored inside the machine."
                        )
                    ]
                ) {
                    Task { await store?.delete(id: machine.id) }
                }
            }
            .alert(
                "Machine Action Failed",
                isPresented: Binding(
                    get: { store?.lastError != nil },
                    set: { if !$0 { store?.dismissError() } }
                )
            ) {
                Button("OK") { store?.dismissError() }
            } message: {
                Text(store?.lastError ?? "Unknown error")
            }
    }

    @ViewBuilder
    private var content: some View {
        if let store {
            switch store.phase {
            case .loading:
                ProgressView("Loading machines…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load Machines", systemImage: "desktopcomputer")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await store.refresh() } }
                }
            case .loaded(let machines):
                machineDashboard(machines, store: store)
            }
        } else {
            ContentUnavailableView("Runtime unavailable", systemImage: "desktopcomputer")
        }
    }

    private func machineDashboard(_ machines: [MachineSummary], store: MachinesStore) -> some View {
        VStack(spacing: 0) {
            machineHeader(machines)
            Divider()
            if machines.isEmpty {
                ContentUnavailableView {
                    Label("No Machines", systemImage: "desktopcomputer")
                } description: {
                    Text("Create a persistent Apple container machine with its own CPU, memory, and virtual disk.")
                } actions: {
                    Button("Create Machine") { showingCreate = true }
                        .buttonStyle(.borderedProminent)
                        .tint(CapsulePalette.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    machineCollection(machines, store: store)
                        .frame(minWidth: 390, idealWidth: 620)
                    MachineDetailPane(store: store) { machine in
                        pendingDelete = machines.first(where: { $0.id == machine.id })
                    }
                    .frame(minWidth: 390, idealWidth: 520)
                }
            }
        }
    }

    private func machineHeader(_ machines: [MachineSummary]) -> some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Persistent machines")
                    .font(.title3.weight(.semibold))
                Text("Start, stop, inspect, and follow runtime or boot logs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label("\(machines.count(where: { $0.state == .running })) running", systemImage: "play.circle.fill")
                .foregroundStyle(Color(nsColor: .systemGreen))
            Label("\(machines.reduce(0) { $0 + $1.cpus }) CPUs", systemImage: "cpu")
            Label(CapsuleFormatting.bytes(totalMemory(machines)), systemImage: "memorychip")
        }
        .font(.callout)
        .padding(.horizontal, 18)
        .frame(minHeight: 68)
    }

    private func machineCollection(_ machines: [MachineSummary], store: MachinesStore) -> some View {
        ScrollView {
            switch collectionMode {
            case .cards:
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 270, maximum: 410), spacing: 12)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(machines) { machine in machineSurface(machine, store: store, layout: .card) }
                }
            case .list:
                LazyVStack(spacing: 6) {
                    ForEach(machines) { machine in machineSurface(machine, store: store, layout: .row) }
                }
            }
        }
        .contentMargins(16, for: .scrollContent)
    }

    private func machineSurface(
        _ machine: MachineSummary,
        store: MachinesStore,
        layout: CapsuleResourceSurfaceLayout
    ) -> some View {
        CapsuleResourceSurface(
            layout: layout,
            isSelected: store.selectedMachineID == machine.id,
            accessibilityLabel: "Machine \(machine.id), \(machine.state.title)",
            select: { Task { await store.select(id: machine.id) } }
        ) {
            MachineSummaryView(machine: machine, compact: layout == .row)
        } actions: {
            if machine.state == .running {
                Button("Stop", systemImage: "stop.fill") {
                    Task { await store.stop(id: machine.id) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Stop \(machine.id)")
            } else if machine.state == .stopped {
                Button("Start", systemImage: "play.fill") {
                    Task { await store.start(id: machine.id) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(Color(nsColor: .systemGreen))
                .help("Start \(machine.id)")
            }
            Button("Delete", systemImage: "trash") { pendingDelete = machine }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(Color(nsColor: .systemRed))
                .help("Delete \(machine.id)")
        }
        .disabled(store.action != .idle)
        .contextMenu {
            if machine.state == .running {
                Button("Stop") { Task { await store.stop(id: machine.id) } }
            } else if machine.state == .stopped {
                Button("Start") { Task { await store.start(id: machine.id) } }
            }
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = machine }
        }
    }

    private func totalMemory(_ machines: [MachineSummary]) -> UInt64 {
        machines.reduce(0) { total, machine in
            let (sum, overflow) = total.addingReportingOverflow(machine.memoryBytes)
            return overflow ? .max : sum
        }
    }
}

private struct MachineSummaryView: View {
    let machine: MachineSummary
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 9) {
            HStack(spacing: 8) {
                Circle()
                    .fill(machine.state.color)
                    .frame(width: 8, height: 8)
                Text(machine.id)
                    .font(.headline)
                    .lineLimit(1)
                if machine.isDefault {
                    CapsuleBadge("Default", systemImage: "star.fill")
                }
                Spacer()
                CapsuleBadge(machine.state.title, color: machine.state.color)
            }
            HStack(spacing: 14) {
                Label("\(machine.cpus) CPU\(machine.cpus == 1 ? "" : "s")", systemImage: "cpu")
                Label(CapsuleFormatting.bytes(machine.memoryBytes), systemImage: "memorychip")
            }
            .font(.caption)
            if !compact {
                HStack {
                    Label(machine.ipAddress ?? "No IP address", systemImage: "network")
                    Spacer()
                    if let bytes = machine.diskSizeBytes {
                        Label(CapsuleFormatting.bytes(bytes, style: .file), systemImage: "internaldrive")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct MachineDetailPane: View {
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case logs = "Logs"
        var id: String { rawValue }
    }

    let store: MachinesStore
    let delete: (MachineDetail) -> Void
    @State private var tab = Tab.overview

    var body: some View {
        if let detail = store.selectedDetail {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(detail.id)
                                .font(.title2.weight(.semibold))
                            CapsuleBadge(detail.state.title, color: detail.state.color)
                        }
                        Text(detail.imageReference)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if store.action != .idle { ProgressView().controlSize(.small) }
                    if detail.state == .running {
                        Button("Stop", systemImage: "stop.fill") {
                            Task { await store.stop(id: detail.id) }
                        }
                    } else if detail.state == .stopped {
                        Button("Start", systemImage: "play.fill") {
                            Task { await store.start(id: detail.id) }
                        }
                        .tint(Color(nsColor: .systemGreen))
                    }
                    Button("Delete", systemImage: "trash") { delete(detail) }
                        .foregroundStyle(Color(nsColor: .systemRed))
                }
                .buttonStyle(.bordered)
                .disabled(store.action != .idle)
                .padding(16)

                Picker("Machine detail", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                Divider()

                switch tab {
                case .overview:
                    MachineOverview(detail: detail)
                case .logs:
                    MachineLogsPane(store: store, machineID: detail.id)
                }
            }
        } else if let id = store.selectedMachineID {
            ProgressView("Inspecting \(id)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Select a Machine",
                systemImage: "sidebar.right",
                description: Text("Machine configuration, controls, and logs appear here.")
            )
        }
    }
}

private struct MachineOverview: View {
    let detail: MachineDetail

    var body: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
                detailRow("Image", detail.imageReference, symbol: "opticaldisc")
                detailRow("Platform", "\(detail.operatingSystem)/\(detail.architecture)", symbol: "cpu")
                detailRow("CPUs", "\(detail.cpus)", symbol: "cpu")
                detailRow("Memory", CapsuleFormatting.bytes(detail.memoryBytes), symbol: "memorychip")
                detailRow("Disk", detail.diskSizeBytes.map { CapsuleFormatting.bytes($0, style: .file) } ?? "Not reported", symbol: "internaldrive")
                detailRow("IP address", detail.ipAddress ?? "Not assigned", symbol: "network")
                detailRow("Home mount", detail.homeMount.title, symbol: "house")
                detailRow("Container ID", detail.containerID ?? "Not reported", symbol: "shippingbox")
                detailRow("Created", detail.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? "Not reported", symbol: "calendar")
                detailRow("Started", detail.startedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Not running", symbol: "clock")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func detailRow(_ label: String, _ value: String, symbol: String) -> some View {
        GridRow {
            Label(label, systemImage: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .gridColumnAlignment(.leading)
        }
    }
}

private struct MachineLogsPane: View {
    let store: MachinesStore
    let machineID: String
    @State private var source = MachineLogSource.standard

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Log source", selection: $source) {
                    Text("Runtime").tag(MachineLogSource.standard)
                    Text("Boot").tag(MachineLogSource.boot)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                Spacer()
                if let error = store.logError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .lineLimit(1)
                } else {
                    Label("Following", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .systemGreen))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if store.logLines.isEmpty {
                            Text("Waiting for \(source == .boot ? "boot" : "runtime") logs…")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(store.logLines.indices, id: \.self) { index in
                                Text(store.logLines[index].text)
                                    .id(index)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(CapsulePalette.consoleInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .background(CapsulePalette.consoleBackground)
                .onChange(of: store.logLines.count) { _, count in
                    guard count > 0 else { return }
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
        .task(id: "\(machineID)|\(source.rawValue)") {
            await store.showLogs(id: machineID, source: source)
        }
        .onDisappear { store.stopLogs() }
    }
}

private struct CreateMachineSheet: View {
    let store: MachinesStore

    @Environment(\.dismiss) private var dismiss
    @State private var image = ""
    @State private var name = ""
    @State private var platform = ""
    @State private var customizeResources = false
    @State private var cpus = 2
    @State private var memoryGiB = 4
    @State private var homeMount = MachineHomeMount.readWrite
    @State private var bootAfterCreation = true
    @State private var setAsDefault = false
    @State private var nestedVirtualization = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 11) {
                Image(systemName: "desktopcomputer.and.arrow.down")
                    .font(.title2)
                    .foregroundStyle(CapsulePalette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create Machine")
                        .font(.title2.weight(.semibold))
                    Text("Create a persistent virtual machine managed by Apple's container runtime.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Form {
                TextField("Image", text: $image, prompt: Text("Image reference"))
                TextField("Name", text: $name, prompt: Text("Optional; generated by the runtime"))
                TextField("Platform", text: $platform, prompt: Text("Optional, for example linux/arm64"))
                Picker("Home directory", selection: $homeMount) {
                    ForEach(MachineHomeMount.allCases, id: \.self) { mount in
                        Text(mount.title).tag(mount)
                    }
                }
                Toggle("Customize CPU and memory", isOn: $customizeResources)
                if customizeResources {
                    Stepper("CPUs: \(cpus)", value: $cpus, in: 1...64)
                    Stepper("Memory: \(memoryGiB) GiB", value: $memoryGiB, in: 1...256)
                }
                Toggle("Boot after creation", isOn: $bootAfterCreation)
                Toggle("Make this the default machine", isOn: $setAsDefault)
                Toggle("Enable nested virtualization", isOn: $nestedVirtualization)
            }
            HStack {
                if store.action != .idle { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create Machine") {
                    Task {
                        await store.create(MachineCreationInput(
                            imageReference: image,
                            name: name,
                            platform: platform,
                            cpus: customizeResources ? cpus : nil,
                            memoryGiB: customizeResources ? memoryGiB : nil,
                            homeMount: homeMount,
                            bootAfterCreation: bootAfterCreation,
                            setAsDefault: setAsDefault,
                            nestedVirtualization: nestedVirtualization
                        ))
                        if store.lastError == nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(CapsulePalette.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(image.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.action != .idle)
            }
        }
        .padding(22)
        .frame(width: 580)
    }
}

private extension MachineState {
    var title: String {
        switch self {
        case .unknown: "Unknown"
        case .stopped: "Stopped"
        case .running: "Running"
        case .stopping: "Stopping"
        case .other(let value): value.capitalized
        }
    }

    var color: Color {
        switch self {
        case .running: Color(nsColor: .systemGreen)
        case .stopping: Color(nsColor: .systemOrange)
        case .stopped, .unknown, .other: Color(nsColor: .systemGray)
        }
    }
}

private extension MachineHomeMount {
    var title: String {
        switch self {
        case .readWrite: "Read and write"
        case .readOnly: "Read only"
        case .none: "Do not mount"
        }
    }
}
