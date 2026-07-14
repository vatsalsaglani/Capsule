import AppCore
import ContainerClient
import SwiftUI

struct ImagesView: View {
    let session: RuntimeSession

    @State private var store: ImagesStore?
    @State private var showingPullSheet = false
    @State private var pullReference = ""
    @State private var pullPlatform = ""
    @State private var selection: String?
    @AppStorage("imageCollectionMode") private var collectionMode = CapsuleCollectionMode.cards

    init(session: RuntimeSession) {
        self.session = session
        _store = State(initialValue: session.makeImagesStore())
    }

    var body: some View {
        Group {
            if let store {
                content(store: store)
            } else {
                ContentUnavailableView {
                    Label("Runtime Not Found", systemImage: "opticaldisc")
                } description: {
                    Text(runtimeMissingMessage)
                }
            }
        }
        .navigationTitle("Images")
        .toolbar {
            CapsuleCollectionModePicker(selection: $collectionMode)
            Button {
                showingPullSheet = true
            } label: {
                Label("Pull Image", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(CapsulePalette.accent)
            .disabled(store == nil)
        }
        .sheet(isPresented: $showingPullSheet) {
            if let store {
                PullImageSheet(store: store, reference: $pullReference, platform: $pullPlatform)
            }
        }
        .alert(
            "Image Action Failed",
            isPresented: Binding(
                get: { store?.lastActionError != nil },
                set: { if !$0 { store?.dismissActionError() } }
            )
        ) {
            Button("OK") { store?.dismissActionError() }
        } message: {
            Text(store?.lastActionError?.message ?? "Unknown error")
        }
        .task { await store?.refresh() }
    }

    private var runtimeMissingMessage: String {
        if case .runtimeMissing(let message) = session.containers.phase { return message }
        return "The container runtime couldn't be reached."
    }

    @ViewBuilder
    private func content(store: ImagesStore) -> some View {
        VStack(spacing: 0) {
            switch store.phase {
            case .loading:
                ProgressView("Loading images…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load Images", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            case .loaded(let images) where images.isEmpty:
                ContentUnavailableView {
                    Label("No Images", systemImage: "opticaldisc")
                } description: {
                    Text("Pull an image to get started.")
                } actions: {
                    Button("Pull Image") { showingPullSheet = true }
                        .buttonStyle(.borderedProminent)
                        .tint(CapsulePalette.accent)
                }
            case .loaded(let images):
                imageCollection(images, store: store)
            }
            deferredFeaturesNote
        }
    }

    private func imageCollection(_ images: [ImageSummary], store: ImagesStore) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Local image library")
                        .font(.title3.weight(.semibold))
                    Text("\(images.count) image\(images.count == 1 ? "" : "s") available to containers and Compose projects.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                CapsuleBadge(
                    "\(images.count(where: { store.isInUse($0, byContainers: session.containers.currentContainers) })) in use",
                    systemImage: "shippingbox.fill",
                    color: Color(nsColor: .systemOrange)
                )
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 64)
            Divider()
            ScrollView {
                switch collectionMode {
                case .cards:
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 290, maximum: 430), spacing: 12)],
                        alignment: .leading,
                        spacing: 12
                    ) {
                        ForEach(images) { image in
                            imageRow(image, store: store, layout: .card)
                        }
                    }
                case .list:
                    LazyVStack(spacing: 6) {
                        ForEach(images) { image in
                            imageRow(image, store: store, layout: .row)
                        }
                    }
                }
            }
            .contentMargins(18, for: .scrollContent)
        }
    }

    private func imageRow(
        _ image: ImageSummary,
        store: ImagesStore,
        layout: CapsuleResourceSurfaceLayout
    ) -> some View {
        ImageRow(
            image: image,
            inUse: store.isInUse(image, byContainers: session.containers.currentContainers),
            store: store,
            iconCache: session.imageIcons,
            layout: layout,
            isSelected: selection == image.id,
            select: { selection = image.id }
        )
    }

    private var deferredFeaturesNote: some View {
        Text("Push, prune, registry login, and per-image disk size aren't available on the current runtime surface yet.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(minHeight: 32, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CapsulePalette.elevated.opacity(0.35))
    }
}

private struct ImageRow: View {
    let image: ImageSummary
    let inUse: Bool
    let store: ImagesStore
    let iconCache: ImageIconCache
    let layout: CapsuleResourceSurfaceLayout
    let isSelected: Bool
    let select: () -> Void

    @State private var showingTagAlert = false
    @State private var tagTarget = ""

    var body: some View {
        CapsuleResourceSurface(
            layout: layout,
            isSelected: isSelected,
            accessibilityLabel: accessibilityLabel,
            select: select
        ) {
            summary
        } actions: {
            Button("Tag", systemImage: "tag") { showingTagAlert = true }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Tag \(image.reference)")
            Button("Delete", systemImage: "trash") {
                Task { await store.delete(reference: image.reference) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(Color(nsColor: .systemRed))
            .help("Delete \(image.reference)")
        }
        .contextMenu { rowActions }
        .alert("Tag Image", isPresented: $showingTagAlert) {
            TextField("New tag (e.g. myrepo/app:latest)", text: $tagTarget)
            Button("Tag") {
                let target = tagTarget.trimmingCharacters(in: .whitespacesAndNewlines)
                tagTarget = ""
                guard !target.isEmpty else { return }
                Task { await store.tag(source: image.reference, target: target) }
            }
            Button("Cancel", role: .cancel) { tagTarget = "" }
        } message: {
            Text("Create another reference for \(image.reference).")
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: layout == .card ? 9 : 4) {
            HStack(spacing: 7) {
                ContainerImageIcon(reference: image.reference, cache: iconCache)
                Text(image.reference)
                    .font(.headline)
                    .lineLimit(1)
                if inUse {
                    CapsuleBadge("In use", systemImage: "shippingbox.fill", color: Color(nsColor: .systemOrange))
                }
                Spacer()
                if let createdAt = image.createdAt {
                    Text(createdAt, style: .date)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let digest = image.digest {
                Text(shortDigest(digest))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text(platformsSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(layout == .card ? 2 : 1)
        }
    }

    @ViewBuilder
    private var rowActions: some View {
        Button("Tag…") { showingTagAlert = true }
        Divider()
        Button("Delete", role: .destructive) {
            Task { await store.delete(reference: image.reference) }
        }
    }

    private var platformsSummary: String {
        guard !image.platforms.isEmpty else { return "No platform metadata reported" }
        return image.platforms.map { platform in
            if let variant = platform.variant {
                return "\(platform.os)/\(platform.architecture)/\(variant)"
            }
            return "\(platform.os)/\(platform.architecture)"
        }.joined(separator: ", ")
    }

    private func shortDigest(_ digest: String) -> String {
        guard let range = digest.range(of: "sha256:") else { return digest }
        return "sha256:" + digest[range.upperBound...].prefix(12)
    }

    private var accessibilityLabel: String {
        image.reference + (inUse ? ", in use" : "")
    }
}

private struct PullImageSheet: View {
    let store: ImagesStore
    @Binding var reference: String
    @Binding var platform: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(CapsulePalette.accent)
                Text("Pull Image")
                    .font(.title2.weight(.semibold))
            }
            TextField("Reference (e.g. docker.io/library/nginx:latest)", text: $reference)
                .textFieldStyle(.roundedBorder)
                .disabled(isPulling)
            TextField("Platform (optional, e.g. linux/arm64)", text: $platform)
                .textFieldStyle(.roundedBorder)
                .disabled(isPulling)

            progressSection

            HStack {
                Spacer()
                Button("Close") {
                    store.dismissPull()
                    dismiss()
                }
                Button("Pull") {
                    store.pull(reference: reference, platform: platform.isEmpty ? nil : platform)
                }
                .buttonStyle(.borderedProminent)
                .tint(CapsulePalette.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(reference.isEmpty || isPulling)
            }
        }
        .padding(22)
        .frame(minWidth: 520, minHeight: 340)
    }

    private var isPulling: Bool {
        if case .pulling = store.pullPhase { return true }
        return false
    }

    @ViewBuilder
    private var progressSection: some View {
        switch store.pullPhase {
        case .idle:
            ContentUnavailableView("Ready to Pull", systemImage: "arrow.down.circle", description: Text("Enter an image reference above."))
                .frame(maxWidth: .infinity, minHeight: 150)
        case .pulling(let lines):
            consoleView(lines: lines)
        case .done:
            Label("Pull complete", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color(nsColor: .systemGreen))
                .frame(maxWidth: .infinity, minHeight: 150)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(nsColor: .systemRed))
                .frame(maxWidth: .infinity, minHeight: 150)
        }
    }

    private func consoleView(lines: [String]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(lines.enumerated(), id: \.offset) { index, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(CapsulePalette.consoleInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(10)
            }
            .frame(minHeight: 170)
            .background(CapsulePalette.consoleBackground, in: .rect(cornerRadius: 9))
            .onChange(of: lines.count) { _, _ in
                guard let lastIndex = lines.indices.last else { return }
                proxy.scrollTo(lastIndex, anchor: .bottom)
            }
        }
    }
}
