import SwiftUI
import TerminalKit

/// Tab bar over `TerminalSessionManager.tabs` + the SwiftTerm-backed host
/// view for the selected session. Opens one tab automatically the first
/// time it appears for a given container (common terminal-app convention —
/// an empty Terminal tab with no shell is dead weight).
struct TerminalTabsView: View {
    let manager: TerminalSessionManager
    let containerID: String

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            content
        }
        .task(id: containerID) {
            if manager.tabs.isEmpty {
                await manager.openTab(containerID: containerID)
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(manager.tabs) { tab in
                tabButton(tab)
            }
            Spacer()
            Button {
                Task { await manager.openTab(containerID: containerID) }
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New terminal tab")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func tabButton(_ tab: TerminalSessionManager.Tab) -> some View {
        let isSelected = tab.id == manager.selectedTabID
        return HStack(spacing: 4) {
            Text(title(for: tab))
                .font(.caption)
                .lineLimit(1)
            Button {
                Task { await manager.closeTab(id: tab.id) }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .help("Close tab")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(isSelected ? Color.secondary.opacity(0.2) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { manager.selectedTabID = tab.id }
        // State (connecting/connected/exited/failed) is never carried by
        // color alone (§6.5) — the label text already says it.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title(for: tab)) tab")
    }

    private func title(for tab: TerminalSessionManager.Tab) -> String {
        switch tab.state {
        case .connecting: "Connecting…"
        case .connected(let shell): shell
        case .exited: "Exited"
        case .failed: "Failed"
        }
    }

    @ViewBuilder
    private var content: some View {
        if let selectedID = manager.selectedTabID,
           let tab = manager.tabs.first(where: { $0.id == selectedID }) {
            tabContent(tab)
        } else {
            ContentUnavailableView("No Terminal Tabs", systemImage: "terminal")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: TerminalSessionManager.Tab) -> some View {
        switch tab.state {
        case .connecting:
            ProgressView("Connecting…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Solid dark surface even while connecting — terminals are
                // never translucent (§6.2/§6.7), matching the connected
                // state's own host view background.
                .background(Color(red: 0.086, green: 0.086, blue: 0.094))
        case .connected:
            if let session = manager.session(for: tab.id) {
                TerminalHostView(session: session)
            }
        case .exited(let code):
            ContentUnavailableView(
                "Session Exited",
                systemImage: "power",
                description: code.map { Text("Exit code \($0)") }
            )
        case .failed(let message):
            ContentUnavailableView(
                "Terminal Failed",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }
}
