import AppCore
import BuildManager
import ContainerClient
import SwiftUI
import UniformTypeIdentifiers

struct BuildsView: View {
    let session: RuntimeSession

    @State private var store: BuildsStore?
    @State private var selection: BuildID?
    @State private var showingBuild = false
    @State private var showingClearConfirmation = false
    @AppStorage("buildCollectionMode") private var collectionMode = CapsuleCollectionMode.cards

    init(session: RuntimeSession) {
        self.session = session
        _store = State(initialValue: session.makeBuildsStore())
    }

    var body: some View {
        content
            .navigationTitle("Builds")
            .toolbar {
                CapsuleCollectionModePicker(selection: $collectionMode)
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await store?.refresh() }
                }
                .help("Refresh builder status and build history")
                Button("Build Image", systemImage: "hammer.fill") { showingBuild = true }
                    .buttonStyle(.borderedProminent)
                    .tint(CapsulePalette.accent)
                    .keyboardShortcut("b", modifiers: [.command])
                    .disabled(store?.isBuilding == true)
            }
            .task { await store?.refresh() }
            .sheet(isPresented: $showingBuild) {
                if let store { NewBuildSheet(store: store) }
            }
            .confirmationDialog(
                "Clear build history?",
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear History", role: .destructive) {
                    Task {
                        await store?.clearHistory()
                        selection = nil
                    }
                }
            } message: {
                Text("This removes Capsule's saved build records and output. It does not delete any images.")
            }
            .alert(
                "Build Action Failed",
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
                ProgressView("Loading builder and history…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load Builds", systemImage: "hammer")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await store.refresh() } }
                }
            case .loaded:
                buildDashboard(store)
            }
        } else {
            ContentUnavailableView("Runtime unavailable", systemImage: "hammer")
        }
    }

    private func buildDashboard(_ store: BuildsStore) -> some View {
        VStack(spacing: 0) {
            BuilderStatusBar(store: store)
            if store.isBuilding {
                Divider()
                ActiveBuildView(store: store)
                    .frame(minHeight: 190, idealHeight: 250, maxHeight: 320)
            }
            Divider()
            historyHeader(store)
            Divider()
            if store.history.isEmpty {
                ContentUnavailableView {
                    Label("No Build History", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                } description: {
                    Text("Build a Dockerfile to create an image and keep its output here.")
                } actions: {
                    Button("Build Image") { showingBuild = true }
                        .buttonStyle(.borderedProminent)
                        .tint(CapsulePalette.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    buildCollection(store.history)
                        .frame(minWidth: 390, idealWidth: 620)
                    BuildDetailView(record: selectedRecord(in: store.history))
                        .frame(minWidth: 330, idealWidth: 440, maxWidth: 620)
                }
            }
        }
    }

    private func historyHeader(_ store: BuildsStore) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Build history")
                    .font(.headline)
                Text("\(store.history.count) saved build\(store.history.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Clear", systemImage: "trash") { showingClearConfirmation = true }
                .buttonStyle(.borderless)
                .foregroundStyle(Color(nsColor: .systemRed))
                .disabled(store.history.isEmpty || store.isBuilding)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 56)
    }

    private func buildCollection(_ records: [BuildRecord]) -> some View {
        ScrollView {
            switch collectionMode {
            case .cards:
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 260, maximum: 390), spacing: 12)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(records) { record in buildSurface(record, layout: .card) }
                }
            case .list:
                LazyVStack(spacing: 6) {
                    ForEach(records) { record in buildSurface(record, layout: .row) }
                }
            }
        }
        .contentMargins(16, for: .scrollContent)
    }

    private func buildSurface(_ record: BuildRecord, layout: CapsuleResourceSurfaceLayout) -> some View {
        CapsuleResourceSurface(
            layout: layout,
            isSelected: selection == record.id,
            accessibilityLabel: "Build \(record.request.tags.joined(separator: ", ")), \(record.state.title)",
            select: { selection = record.id }
        ) {
            BuildSummaryView(record: record, compact: layout == .row)
        } actions: {
            Button("Show Details", systemImage: "sidebar.right") { selection = record.id }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Show build details")
        }
        .contextMenu {
            Button("Show Details") { selection = record.id }
        }
    }

    private func selectedRecord(in records: [BuildRecord]) -> BuildRecord? {
        guard let selection else { return nil }
        return records.first(where: { $0.id == selection })
    }
}

private struct BuilderStatusBar: View {
    let store: BuildsStore

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "shippingbox.and.arrow.backward.fill")
                .font(.title2)
                .foregroundStyle(CapsulePalette.accent)
                .frame(width: 36, height: 36)
                .background(CapsulePalette.accent.opacity(0.12), in: .rect(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Image builder")
                        .font(.headline)
                    CapsuleBadge(
                        store.builderStatus.state.title,
                        systemImage: store.builderStatus.state.symbol,
                        color: store.builderStatus.state.color
                    )
                }
                HStack(spacing: 12) {
                    if let cpus = store.builderStatus.cpus {
                        Label("\(cpus) CPU\(cpus == 1 ? "" : "s")", systemImage: "cpu")
                    }
                    if let bytes = store.builderStatus.memoryBytes {
                        Label(CapsuleFormatting.bytes(bytes), systemImage: "memorychip")
                    }
                    if store.builderStatus.state == .absent {
                        Text("Created automatically by a build, or start it now.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if store.builderAction == .working { ProgressView().controlSize(.small) }
            switch store.builderStatus.state {
            case .absent, .stopped:
                Button("Start", systemImage: "play.fill") {
                    Task { await store.startBuilder() }
                }
                .tint(Color(nsColor: .systemGreen))
            case .running:
                Button("Stop", systemImage: "stop.fill") {
                    Task { await store.stopBuilder() }
                }
            case .unknown:
                EmptyView()
            }
            Button("Reset", systemImage: "arrow.counterclockwise") {
                Task { await store.resetBuilder() }
            }
            .help("Delete and recreate the builder")
        }
        .buttonStyle(.bordered)
        .disabled(store.builderAction == .working || store.isBuilding)
        .padding(.horizontal, 18)
        .frame(minHeight: 72)
    }
}

private struct ActiveBuildView: View {
    let store: BuildsStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.activeRecord?.request.tags.first ?? "Preparing build")
                        .font(.headline)
                    Text(store.tagging.map { "Tagging \($0)" } ?? "Build output")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", systemImage: "xmark") {
                    Task { await store.cancelActiveBuild() }
                }
                .buttonStyle(.bordered)
                .tint(Color(nsColor: .systemRed))
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            BuildOutputConsole(lines: store.liveOutput.map(\.message), emptyMessage: "Waiting for builder output…")
        }
    }
}

private struct BuildSummaryView: View {
    let record: BuildRecord
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 9) {
            HStack(spacing: 8) {
                Circle()
                    .fill(record.state.color)
                    .frame(width: 8, height: 8)
                Text(record.request.tags.first ?? "Untagged image")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                CapsuleBadge(record.state.title, color: record.state.color)
            }
            Text(record.request.contextPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(compact ? 1 : 2)
            HStack {
                Label(record.startedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                Spacer()
                if record.request.tags.count > 1 {
                    Label("\(record.request.tags.count) tags", systemImage: "tag")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct BuildDetailView: View {
    let record: BuildRecord?

    var body: some View {
        if let record {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.request.tags.first ?? "Untagged image")
                                .font(.title3.weight(.semibold))
                            Text(record.state.title)
                                .foregroundStyle(record.state.color)
                        }
                        Spacer()
                        Image(systemName: record.state.symbol)
                            .font(.title2)
                            .foregroundStyle(record.state.color)
                    }
                    LabeledContent("Context", value: record.request.contextPath)
                    LabeledContent("Dockerfile", value: record.request.dockerfilePath)
                    LabeledContent("Tags", value: record.request.tags.joined(separator: ", "))
                    if let platform = record.request.platform { LabeledContent("Platform", value: platform) }
                    if let target = record.request.target { LabeledContent("Target", value: target) }
                    if !record.request.argumentKeys.isEmpty {
                        LabeledContent("Build argument keys", value: record.request.argumentKeys.joined(separator: ", "))
                    }
                    LabeledContent("Started", value: record.startedAt.formatted(date: .abbreviated, time: .standard))
                    if let error = record.failureMessage {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(Color(nsColor: .systemRed))
                            .textSelection(.enabled)
                    }
                }
                .font(.callout)
                .padding(18)
                Divider()
                BuildOutputConsole(
                    lines: record.output.map(\.message),
                    emptyMessage: "No output was saved for this build."
                )
            }
        } else {
            ContentUnavailableView(
                "Select a Build",
                systemImage: "sidebar.right",
                description: Text("Build details and saved output appear here.")
            )
        }
    }
}

private struct BuildOutputConsole: View {
    let lines: [String]
    let emptyMessage: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if lines.isEmpty {
                        Text(emptyMessage)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(lines.indices, id: \.self) { index in
                            Text(lines[index])
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
            .onChange(of: lines.count) { _, count in
                guard count > 0 else { return }
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
    }
}

private struct NewBuildSheet: View {
    let store: BuildsStore

    @Environment(\.dismiss) private var dismiss
    @State private var contextDirectory: URL?
    @State private var dockerfile: URL?
    @State private var tags = ""
    @State private var arguments = ""
    @State private var target = ""
    @State private var platform = ""
    @State private var noCache = false
    @State private var pullBaseImages = false
    @State private var choosingContext = false
    @State private var choosingDockerfile = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 11) {
                Image(systemName: "hammer.fill")
                    .font(.title2)
                    .foregroundStyle(CapsulePalette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Build an Image")
                        .font(.title2.weight(.semibold))
                    Text("Capsule detects Dockerfile in the selected context unless you choose another file.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Form {
                LabeledContent("Context") {
                    HStack {
                        Text(contextDirectory?.path(percentEncoded: false) ?? "Not selected")
                            .foregroundStyle(contextDirectory == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { choosingContext = true }
                    }
                }
                LabeledContent("Dockerfile") {
                    HStack {
                        Text(dockerfile?.lastPathComponent ?? "Auto-detect")
                            .foregroundStyle(.secondary)
                        Button("Choose…") { choosingDockerfile = true }
                        if dockerfile != nil { Button("Clear") { dockerfile = nil } }
                    }
                }
                TextField("Image tags", text: $tags, prompt: Text("example/app:latest, example/app:dev"))
                TextField("Target stage", text: $target, prompt: Text("Optional"))
                TextField("Platform", text: $platform, prompt: Text("Optional, for example linux/arm64"))
                LabeledContent("Build arguments") {
                    TextField(
                        "Build arguments",
                        text: $arguments,
                        prompt: Text("One KEY=VALUE pair per line"),
                        axis: .vertical
                    )
                        .font(.body.monospaced())
                        .lineLimit(3...8)
                        .help("One KEY=VALUE pair per line. Values are not stored in build history.")
                }
                Toggle("Do not use build cache", isOn: $noCache)
                Toggle("Pull base images before building", isOn: $pullBaseImages)
            }
            HStack {
                Text("Build output remains visible in Capsule history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Build Image") {
                    guard let contextDirectory else { return }
                    Task {
                        await store.start(BuildFormInput(
                            contextDirectory: contextDirectory,
                            dockerfile: dockerfile,
                            tags: tags,
                            arguments: arguments,
                            target: target,
                            platform: platform,
                            noCache: noCache,
                            pullBaseImages: pullBaseImages
                        ))
                        if store.lastError == nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(CapsulePalette.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(contextDirectory == nil || tags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 650)
        .fileImporter(isPresented: $choosingContext, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { contextDirectory = url }
        }
        .fileDialogMessage("Choose the directory used as the image build context.")
        .fileDialogConfirmationLabel("Choose Context")
        .fileImporter(isPresented: $choosingDockerfile, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { dockerfile = url }
        }
        .fileDialogMessage("Choose a Dockerfile for this build.")
        .fileDialogConfirmationLabel("Choose Dockerfile")
    }
}

private extension BuildState {
    var title: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .running: Color(nsColor: .systemOrange)
        case .succeeded: Color(nsColor: .systemGreen)
        case .cancelled: Color(nsColor: .systemGray)
        case .failed: Color(nsColor: .systemRed)
        }
    }

    var symbol: String {
        switch self {
        case .running: "progress.indicator"
        case .succeeded: "checkmark.circle.fill"
        case .cancelled: "xmark.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

private extension BuilderState {
    var title: String {
        switch self {
        case .absent: "Not created"
        case .stopped: "Stopped"
        case .running: "Running"
        case .unknown(let value): value.capitalized
        }
    }

    var color: Color {
        switch self {
        case .running: Color(nsColor: .systemGreen)
        case .stopped: Color(nsColor: .systemOrange)
        case .absent, .unknown: Color(nsColor: .systemGray)
        }
    }

    var symbol: String {
        switch self {
        case .running: "checkmark.circle.fill"
        case .stopped: "pause.circle.fill"
        case .absent: "circle.dashed"
        case .unknown: "questionmark.circle"
        }
    }
}
