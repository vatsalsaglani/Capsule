import AppCore
import ContainerClient
import SwiftUI
import TerminalKit

/// The Containers screen (P1B B3) — list bound to the shared
/// `ContainerListStore.phase`, trailing inspector bound to a
/// `ContainerDetailStore` built from the same `RuntimeSession`. Shared
/// verbatim with the `#if DEBUG` feel prototype (`FeelPrototypeDemoView`),
/// which passes a scripted `RuntimeSession` instead of the real one — same
/// view code, same production data path, per the P1B B2+B3 brief.
struct ContainersView: View {
    let session: RuntimeSession

    @State private var detailStore: ContainerDetailStore?
    /// Built once per screen instance, same "construct once, share
    /// everywhere" posture as `detailStore` (P1C — `RuntimeSession`'s doc
    /// comment).
    @State private var terminalManager: TerminalSessionManager?
    @State private var selection: String?

    init(session: RuntimeSession) {
        self.session = session
        _detailStore = State(initialValue: session.makeDetailStore())
        _terminalManager = State(initialValue: session.makeTerminalSessionManager())
    }

    var body: some View {
        listContent
            .navigationTitle("Containers")
            .inspector(isPresented: inspectorPresented) {
                if let detailStore {
                    ContainerInspector(store: detailStore, terminalManager: terminalManager)
                }
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
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .systemOrange).opacity(0.12))
                // Dimmed, not blanked — the last-known list stays visible and
                // browsable through a transient outage (§6.1: never trap).
                containerList(lastKnown)
                    .disabled(true)
                    .opacity(0.6)
            }
        case .loaded(let containers) where containers.isEmpty:
            ContentUnavailableView {
                Label("No Containers", systemImage: "shippingbox")
            } description: {
                Text("Run one with `container run …` — it appears here live.")
            }
        case .loaded(let containers):
            containerList(containers)
        }
    }

    private func containerList(_ containers: [ContainerSummary]) -> some View {
        List(containers, selection: $selection) { container in
            ContainerRow(container: container, store: session.containers)
                .tag(container.id)
        }
    }
}
