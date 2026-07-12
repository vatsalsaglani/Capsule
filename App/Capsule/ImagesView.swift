import AppCore
import ContainerClient
import SwiftUI

/// The Images screen (P1B B4) — list bound to `ImagesStore.phase`, a pull
/// sheet with live progress, tag/delete actions, and an in-use warning badge
/// cross-referencing the shared `ContainerListStore`. Push, prune, and
/// registry login are **not** on the frozen `ContainerRuntime` contract (rule
/// 10, AGENTS.md) — omitted entirely rather than wired to a fake action; see
/// `deferredFeaturesNote`. Per-image size is also omitted: `ImageSummary`
/// carries no size field yet (honest scoping, not an oversight).
struct ImagesView: View {
    let session: RuntimeSession

    @State private var store: ImagesStore?
    @State private var showingPullSheet = false
    @State private var pullReference = ""
    @State private var pullPlatform = ""

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
            ToolbarItem {
                Button {
                    showingPullSheet = true
                } label: {
                    Label("Pull Image", systemImage: "arrow.down.circle")
                }
                .disabled(store == nil)
            }
        }
        .sheet(isPresented: $showingPullSheet) {
            if let store {
                PullImageSheet(store: store, reference: $pullReference, platform: $pullPlatform)
            }
        }
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
    private func content(store: ImagesStore) -> some View {
        VStack(spacing: 0) {
            switch store.phase {
            case .loading:
                ProgressView("Loading…")
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
                    Text("Pull one to get started.")
                }
            case .loaded(let images):
                List(images) { image in
                    ImageRow(
                        image: image,
                        inUse: store.isInUse(image, byContainers: session.containers.currentContainers),
                        store: store
                    )
                }
            }
            deferredFeaturesNote
        }
    }

    /// Honest scoping (rule 10, AGENTS.md) — no fake buttons for push,
    /// prune, or registry login: none of them are in `ContainerRuntime`'s
    /// frozen surface yet.
    private var deferredFeaturesNote: some View {
        Text("Push, prune, and registry login aren't available on the current runtime surface yet.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ImageRow: View {
    let image: ImageSummary
    let inUse: Bool
    let store: ImagesStore

    @State private var showingTagAlert = false
    @State private var tagTarget = ""

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(image.reference)
                        .font(.body.weight(.medium))
                    if inUse {
                        // Warning badge, not a block — deleting an in-use
                        // image is still allowed (§6.1: forgiveness over
                        // traps); this only informs.
                        Label("In Use", systemImage: "shippingbox.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color(nsColor: .systemOrange))
                            .labelStyle(.titleAndIcon)
                    }
                }
                if let digest = image.digest {
                    Text(shortDigest(digest))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if !image.platforms.isEmpty {
                    Text(platformsSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let createdAt = image.createdAt {
                Text(createdAt, style: .date)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contextMenu { rowActions }
        .alert("Tag Image", isPresented: $showingTagAlert) {
            TextField("New tag (e.g. myrepo/app:latest)", text: $tagTarget)
            Button("Tag") {
                let target = tagTarget
                tagTarget = ""
                guard !target.isEmpty else { return }
                Task { await store.tag(source: image.reference, target: target) }
            }
            Button("Cancel", role: .cancel) { tagTarget = "" }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var rowActions: some View {
        Button("Tag…") { showingTagAlert = true }
        Divider()
        // Instant + undoable in spirit, same posture as `ContainerRow`'s
        // delete — no confirmation dialog (§6.1's forgiveness rule reserves
        // confirmation for the truly irreversible, e.g. volume delete). The
        // "In Use" badge above is the warning signal for this case.
        Button("Delete", role: .destructive) {
            Task { await store.delete(reference: image.reference) }
        }
    }

    private var platformsSummary: String {
        image.platforms.map { platform in
            if let variant = platform.variant {
                return "\(platform.os)/\(platform.architecture)/\(variant)"
            }
            return "\(platform.os)/\(platform.architecture)"
        }.joined(separator: ", ")
    }

    private func shortDigest(_ digest: String) -> String {
        guard let range = digest.range(of: "sha256:") else { return digest }
        let hash = digest[range.upperBound...]
        return "sha256:" + hash.prefix(12)
    }

    private var accessibilityLabel: String {
        var label = image.reference
        if inUse { label += ", in use" }
        return label
    }
}

/// Pull-with-progress sheet — raw progress lines render on a solid dark
/// console surface (never translucent, §6.2 — same rule the Containers
/// screen's log tab follows).
private struct PullImageSheet: View {
    let store: ImagesStore
    @Binding var reference: String
    @Binding var platform: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pull Image")
                .font(.title3.weight(.semibold))
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
                .keyboardShortcut(.defaultAction)
                .disabled(reference.isEmpty || isPulling)
            }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 280)
    }

    private var isPulling: Bool {
        if case .pulling = store.pullPhase { return true }
        return false
    }

    @ViewBuilder
    private var progressSection: some View {
        switch store.pullPhase {
        case .idle:
            EmptyView()
        case .pulling(let lines):
            consoleView(lines: lines)
        case .done:
            Label("Pull complete", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color(nsColor: .systemGreen))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(nsColor: .systemRed))
        }
    }

    private func consoleView(lines: [String]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            // #EBEBF0 on #161618 — always-dark console
                            // surface, both appearance modes (plan §6.7),
                            // matching `ContainerInspector`'s log tab.
                            .foregroundStyle(Color(red: 0.92, green: 0.92, blue: 0.94))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 140)
            .background(Color(red: 0.086, green: 0.086, blue: 0.094))
            .onChange(of: lines.count) { _, _ in
                guard let lastIndex = lines.indices.last else { return }
                proxy.scrollTo(lastIndex, anchor: .bottom)
            }
        }
    }
}
