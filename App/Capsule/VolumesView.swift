import AppCore
import ContainerClient
import SwiftUI

struct VolumesView: View {
    let session: RuntimeSession

    @State private var store: VolumesStore?
    @State private var selection: String?
    @State private var pendingDelete: VolumeRecord?
    @State private var showingCreate = false
    @State private var showingPrune = false
    @AppStorage("volumeCollectionMode") private var collectionMode = CapsuleCollectionMode.cards

    init(session: RuntimeSession) {
        self.session = session
        _store = State(initialValue: session.makeVolumesStore())
    }

    var body: some View {
        content
            .navigationTitle("Volumes")
            .toolbar {
                CapsuleCollectionModePicker(selection: $collectionMode)
                Button("Prune", systemImage: "trash") { showingPrune = true }
                Button("Create Volume", systemImage: "plus") { showingCreate = true }
                    .buttonStyle(.borderedProminent)
                    .tint(CapsulePalette.accent)
            }
            .task { await store?.refresh() }
            .sheet(isPresented: $showingCreate) {
                if let store { CreateVolumeSheet(store: store) }
            }
            .sheet(item: $pendingDelete) { volume in
                CapsuleDestructiveResourceSheet(
                    title: "Delete \(volume.summary.name)?",
                    message: "The volume and its stored data will be permanently deleted. This cannot be undone.",
                    actionTitle: "Delete Volume",
                    groups: [
                        CapsuleResourcePreviewGroup(
                            "Volume",
                            systemImage: "externaldrive",
                            names: [volume.summary.name],
                            note: capacityDescription(volume)
                        ),
                        CapsuleResourcePreviewGroup(
                            "Affected containers",
                            systemImage: "shippingbox",
                            names: volume.usedBy.map(\.id),
                            note: volume.usedBy.isEmpty
                                ? "No containers currently reference this volume."
                                : "These containers currently reference the volume."
                        )
                    ]
                ) {
                    Task { await store?.delete(volume) }
                }
            }
            .sheet(isPresented: $showingPrune) {
                if let store, case .loaded(let volumes) = store.phase {
                    let candidates = volumes.filter(\.usedBy.isEmpty).map { $0.summary.name }
                    CapsuleDestructiveResourceSheet(
                        title: "Prune unused volumes?",
                        message: "The runtime will delete volumes that are unused when the operation runs. This preview reflects the current Capsule inventory.",
                        actionTitle: "Prune Volumes",
                        groups: [CapsuleResourcePreviewGroup(
                            "Currently unused volumes",
                            systemImage: "externaldrive",
                            names: candidates,
                            note: "Stored data in these volumes will be permanently deleted."
                        )]
                    ) {
                        Task { await store.prune() }
                    }
                }
            }
            .alert(
                "Volume Action Failed",
                isPresented: Binding(
                    get: { store?.actionError != nil },
                    set: { if !$0 { store?.dismissError() } }
                )
            ) {
                Button("OK") { store?.dismissError() }
            } message: {
                Text(store?.actionError ?? "Unknown error")
            }
    }

    @ViewBuilder
    private var content: some View {
        if let store {
            switch store.phase {
            case .loading:
                ProgressView("Loading volumes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView(
                    "Couldn't Load Volumes",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            case .loaded(let volumes) where volumes.isEmpty:
                ContentUnavailableView {
                    Label("No Volumes", systemImage: "externaldrive")
                } description: {
                    Text("Create a named volume to persist container data.")
                } actions: {
                    Button("Create Volume") { showingCreate = true }
                        .buttonStyle(.borderedProminent)
                        .tint(CapsulePalette.accent)
                }
            case .loaded(let volumes):
                volumeCollection(volumes)
            }
        } else {
            ContentUnavailableView("Runtime unavailable", systemImage: "externaldrive")
        }
    }

    private func volumeCollection(_ volumes: [VolumeRecord]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Persistent data")
                        .font(.title3.weight(.semibold))
                    Text("Capacity is the volume allocation, not measured bytes currently used.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label("\(volumes.count(where: { !$0.usedBy.isEmpty })) attached", systemImage: "link")
                Label(CapsuleFormatting.bytes(totalCapacity(volumes), style: .file), systemImage: "externaldrive")
                    .help("Total configured capacity")
            }
            .font(.callout)
            .padding(.horizontal, 18)
            .frame(minHeight: 64)
            Divider()
            ScrollView {
                switch collectionMode {
                case .cards:
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 280, maximum: 410), spacing: 12)],
                        alignment: .leading,
                        spacing: 12
                    ) {
                        ForEach(volumes) { volume in volumeSurface(volume, layout: .card) }
                    }
                case .list:
                    LazyVStack(spacing: 6) {
                        ForEach(volumes) { volume in volumeSurface(volume, layout: .row) }
                    }
                }
            }
            .contentMargins(18, for: .scrollContent)
        }
    }

    private func volumeSurface(_ volume: VolumeRecord, layout: CapsuleResourceSurfaceLayout) -> some View {
        CapsuleResourceSurface(
            layout: layout,
            isSelected: selection == volume.id,
            accessibilityLabel: "Volume \(volume.summary.name), \(usageDescription(volume))",
            select: { selection = volume.id }
        ) {
            VolumeSummaryView(volume: volume, compact: layout == .row)
        } actions: {
            Button("Delete", systemImage: "trash") { pendingDelete = volume }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(Color(nsColor: .systemRed))
                .help("Delete \(volume.summary.name)")
        }
        .contextMenu {
            Button("Delete…", role: .destructive) { pendingDelete = volume }
        }
    }

    private func totalCapacity(_ volumes: [VolumeRecord]) -> UInt64 {
        volumes.reduce(0) { total, volume in
            let (sum, overflow) = total.addingReportingOverflow(volume.summary.sizeInBytes ?? 0)
            return overflow ? .max : sum
        }
    }

    private func usageDescription(_ volume: VolumeRecord) -> String {
        volume.usedBy.isEmpty ? "unused" : "used by \(volume.usedBy.count) container\(volume.usedBy.count == 1 ? "" : "s")"
    }

    private func capacityDescription(_ volume: VolumeRecord) -> String {
        guard let capacity = volume.summary.sizeInBytes else { return "No capacity was reported by the runtime." }
        return "Configured capacity: \(CapsuleFormatting.bytes(capacity, style: .file))."
    }
}

private struct VolumeSummaryView: View {
    let volume: VolumeRecord
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 9) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.fill")
                    .foregroundStyle(CapsulePalette.accent)
                Text(volume.summary.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                CapsuleBadge(ownerTitle, color: ownerColor)
            }
            HStack {
                Label(attachmentTitle, systemImage: volume.usedBy.isEmpty ? "link.badge.plus" : "link")
                    .foregroundStyle(volume.usedBy.isEmpty ? .secondary : Color(nsColor: .systemGreen))
                Spacer()
                Text(capacityTitle)
                    .font(.callout.monospacedDigit().weight(.medium))
            }
            .font(.caption)
            if !compact {
                Text(volume.usedBy.isEmpty
                     ? "No containers currently reference this volume."
                     : volume.usedBy.map(\.id).joined(separator: ", "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var capacityTitle: String {
        guard let value = volume.summary.sizeInBytes else { return "Capacity —" }
        return "Capacity \(CapsuleFormatting.bytes(value, style: .file))"
    }

    private var attachmentTitle: String {
        volume.usedBy.isEmpty ? "Unused" : "\(volume.usedBy.count) attached"
    }

    private var ownerTitle: String {
        switch volume.owner {
        case .capsule(let project): project ?? "Capsule"
        case .external: "External"
        case .system: "System"
        }
    }

    private var ownerColor: Color {
        switch volume.owner {
        case .capsule: CapsulePalette.accent
        case .external, .system: .secondary
        }
    }
}

private struct CreateVolumeSheet: View {
    let store: VolumesStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var capacityBytes: UInt64?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.plus")
                    .font(.title2)
                    .foregroundStyle(CapsulePalette.accent)
                Text("Create Volume")
                    .font(.title2.weight(.semibold))
            }
            Form {
                TextField("Name", text: $name)
                TextField("Capacity in bytes (optional)", value: $capacityBytes, format: .number)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create Volume") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        await store.create(name: trimmed, capacityBytes: capacityBytes)
                        if store.actionError == nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(CapsulePalette.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 470)
    }
}
