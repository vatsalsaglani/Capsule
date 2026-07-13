import AppCore
import ContainerClient
import SwiftUI

struct NetworksView: View {
    let session: RuntimeSession

    @State private var store: NetworksStore?
    @State private var selection: String?
    @State private var pendingDelete: NetworkRecord?
    @State private var showingCreate = false
    @State private var showingPrune = false
    @AppStorage("networkCollectionMode") private var collectionMode = CapsuleCollectionMode.cards

    init(session: RuntimeSession) {
        self.session = session
        _store = State(initialValue: session.makeNetworksStore())
    }

    var body: some View {
        content
            .navigationTitle("Networks")
            .toolbar {
                CapsuleCollectionModePicker(selection: $collectionMode)
                Button("Prune", systemImage: "trash") { showingPrune = true }
                Button("Create Network", systemImage: "plus") { showingCreate = true }
                    .buttonStyle(.borderedProminent)
                    .tint(CapsulePalette.accent)
            }
            .task { await store?.refresh() }
            .sheet(isPresented: $showingCreate) {
                if let store { CreateNetworkSheet(store: store) }
            }
            .sheet(item: $pendingDelete) { network in
                CapsuleDestructiveResourceSheet(
                    title: "Delete \(network.summary.name)?",
                    message: "The network will be deleted. Attached containers may lose connectivity.",
                    actionTitle: "Delete Network",
                    groups: [
                        CapsuleResourcePreviewGroup(
                            "Network",
                            systemImage: "network",
                            names: [network.summary.name],
                            note: networkDescription(network)
                        ),
                        CapsuleResourcePreviewGroup(
                            "Affected containers",
                            systemImage: "shippingbox",
                            names: network.connectedContainers.map(\.id),
                            note: network.connectedContainers.isEmpty
                                ? "No containers are currently attached."
                                : "These containers are currently attached to this network."
                        )
                    ]
                ) {
                    Task { await store?.delete(network) }
                }
            }
            .sheet(isPresented: $showingPrune) {
                if let store, case .loaded(let networks) = store.phase {
                    let candidates = networks
                        .filter { !$0.isBuiltIn && $0.connectedContainers.isEmpty }
                        .map { $0.summary.name }
                    CapsuleDestructiveResourceSheet(
                        title: "Prune unused networks?",
                        message: "The runtime will delete networks that are unused when the operation runs. Built-in networks are always preserved.",
                        actionTitle: "Prune Networks",
                        groups: [CapsuleResourcePreviewGroup(
                            "Currently unused networks",
                            systemImage: "network",
                            names: candidates,
                            note: "This preview reflects the current Capsule inventory."
                        )]
                    ) {
                        Task { await store.prune() }
                    }
                }
            }
            .alert(
                "Network Action Failed",
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
                ProgressView("Loading networks…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView(
                    "Couldn't Load Networks",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            case .loaded(let networks) where networks.isEmpty:
                ContentUnavailableView {
                    Label("No Networks", systemImage: "network")
                } description: {
                    Text("Create a network to connect containers.")
                } actions: {
                    Button("Create Network") { showingCreate = true }
                        .buttonStyle(.borderedProminent)
                        .tint(CapsulePalette.accent)
                }
            case .loaded(let networks):
                networkCollection(networks)
            }
        } else {
            ContentUnavailableView("Runtime unavailable", systemImage: "network")
        }
    }

    private func networkCollection(_ networks: [NetworkRecord]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Container connectivity")
                        .font(.title3.weight(.semibold))
                    Text("See subnets and the exact containers currently attached to each network.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label("\(networks.count(where: { !$0.connectedContainers.isEmpty })) active", systemImage: "point.3.connected.trianglepath.dotted")
                Label("\(networks.reduce(0) { $0 + $1.connectedContainers.count }) attachments", systemImage: "link")
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
                        ForEach(networks) { network in networkSurface(network, layout: .card) }
                    }
                case .list:
                    LazyVStack(spacing: 6) {
                        ForEach(networks) { network in networkSurface(network, layout: .row) }
                    }
                }
            }
            .contentMargins(18, for: .scrollContent)
        }
    }

    private func networkSurface(_ network: NetworkRecord, layout: CapsuleResourceSurfaceLayout) -> some View {
        CapsuleResourceSurface(
            layout: layout,
            isSelected: selection == network.id,
            accessibilityLabel: "Network \(network.summary.name), \(network.connectedContainers.count) connected containers",
            select: { selection = network.id }
        ) {
            NetworkSummaryView(network: network, compact: layout == .row)
        } actions: {
            if !network.isBuiltIn {
                Button("Delete", systemImage: "trash") { pendingDelete = network }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .help("Delete \(network.summary.name)")
            }
        }
        .contextMenu {
            if !network.isBuiltIn {
                Button("Delete…", role: .destructive) { pendingDelete = network }
            }
        }
    }

    private func networkDescription(_ network: NetworkRecord) -> String {
        var parts = [network.summary.mode ?? "Unknown mode"]
        if let subnet = network.summary.status?.ipv4Subnet { parts.append(subnet) }
        return parts.joined(separator: " · ")
    }
}

private struct NetworkSummaryView: View {
    let network: NetworkRecord
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 9) {
            HStack(spacing: 8) {
                Image(systemName: "network")
                    .foregroundStyle(CapsulePalette.accent)
                Text(network.summary.name)
                    .font(.headline)
                    .lineLimit(1)
                if network.isBuiltIn { CapsuleBadge("Built-in", color: .secondary) }
                Spacer()
                CapsuleBadge((network.summary.mode ?? "Unknown").capitalized)
            }
            HStack {
                Label(subnetTitle, systemImage: "number")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Label(attachmentTitle, systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(network.connectedContainers.isEmpty ? .secondary : Color(nsColor: .systemGreen))
            }
            if !compact {
                Text(network.connectedContainers.isEmpty
                     ? "No attached containers"
                     : network.connectedContainers.map(\.id).joined(separator: ", "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var subnetTitle: String {
        network.summary.status?.ipv4Subnet
            ?? network.summary.status?.ipv6Subnet
            ?? "No subnet reported"
    }

    private var attachmentTitle: String {
        "\(network.connectedContainers.count) attached"
    }
}

private struct CreateNetworkSheet: View {
    let store: NetworksStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var internalOnly = false
    @State private var ipv4 = ""
    @State private var ipv6 = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.title2)
                    .foregroundStyle(CapsulePalette.accent)
                Text("Create Network")
                    .font(.title2.weight(.semibold))
            }
            Form {
                TextField("Name", text: $name)
                Toggle("Host-only (internal)", isOn: $internalOnly)
                TextField("IPv4 subnet (optional)", text: $ipv4)
                TextField("IPv6 subnet (optional)", text: $ipv6)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create Network") {
                    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        await store.create(
                            name: trimmedName,
                            isInternal: internalOnly,
                            ipv4Subnet: ipv4.trimmedNilIfEmpty,
                            ipv6Subnet: ipv6.trimmedNilIfEmpty
                        )
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
        .frame(width: 490)
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
