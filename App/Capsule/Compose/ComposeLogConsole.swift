import AppCore
import SwiftUI

struct ComposeLogConsole: View {
    let store: ComposeProjectDetailStore

    @State private var serviceFilter: String?

    private var services: [String] {
        Array(Set(store.services.map(\.service) + store.logs.map(\.service))).sorted()
    }

    private var visibleLogs: [ComposeLogDisplay] {
        guard let serviceFilter else { return store.logs }
        return store.logs.filter { $0.service == serviceFilter }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(.white.opacity(0.12))
            console
        }
        .background(CapsulePalette.consoleBackground)
        .clipShape(.rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.1))
        )
        .padding(16)
        .accessibilityLabel("Multiplexed project logs")
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Label("Project logs", systemImage: "text.alignleft")
                .font(.headline)
                .foregroundStyle(CapsulePalette.consoleInk)
            if store.isFollowingLogs {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text("Following")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(Color(nsColor: .systemGreen))
            } else {
                Text("Paused")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.58))
            }
            Spacer()
            Menu {
                Button("All services") { serviceFilter = nil }
                Divider()
                ForEach(services, id: \.self) { service in
                    Button(service) { serviceFilter = service }
                }
            } label: {
                Label(serviceFilter ?? "All services", systemImage: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button(store.isFollowingLogs ? "Pause" : "Resume", systemImage: store.isFollowingLogs ? "pause.fill" : "play.fill") {
                if store.isFollowingLogs { store.stopLogs() } else { store.startLogs() }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(store.isFollowingLogs ? "Pause log following" : "Resume log following")
            Button("Clear", systemImage: "trash") { store.clearLogs() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Clear displayed logs")
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    private var console: some View {
        ScrollViewReader { proxy in
            ZStack {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(visibleLogs) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 9) {
                                Text(line.service)
                                    .font(.caption2.monospaced().weight(.semibold))
                                    .foregroundStyle(CapsuleServiceColor.color(for: line.service))
                                    .frame(width: 92, alignment: .trailing)
                                Text(line.text)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(CapsulePalette.consoleInk)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(line.id)
                        }
                    }
                    .padding(12)
                }
                if visibleLogs.isEmpty {
                    emptyState
                }
            }
            .onChange(of: visibleLogs.count) { _, _ in
                guard let last = visibleLogs.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let error = store.logError {
            ContentUnavailableView {
                Label("Logs Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") { store.startLogs() }
                    .buttonStyle(.borderedProminent)
                    .tint(CapsulePalette.accent)
            }
            .foregroundStyle(CapsulePalette.consoleInk)
        } else {
            ContentUnavailableView {
                Label(store.isFollowingLogs ? "Waiting for Output" : "Logs Paused", systemImage: "text.alignleft")
            } description: {
                Text(store.isFollowingLogs
                     ? "Logs will appear here as services write to stdout or stderr."
                     : "Resume following to load the latest service output.")
            }
            .foregroundStyle(CapsulePalette.consoleInk)
        }
    }
}
