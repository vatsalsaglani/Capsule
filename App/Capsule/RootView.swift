import AppCore
import RuntimeInstaller
import SwiftUI

// Sidebar sections use direct, specific labels — never "Home" (plan §6.1).
enum SidebarItem: String, CaseIterable, Identifiable {
    case composeProjects
    case containers
    case images
    case builds
    case volumes
    case networks
    case machines
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .composeProjects: "Compose Projects"
        case .containers: "Containers"
        case .images: "Images"
        case .builds: "Builds"
        case .volumes: "Volumes"
        case .networks: "Networks"
        case .machines: "Machines"
        case .system: "System"
        }
    }

    var systemImage: String {
        switch self {
        case .composeProjects: "square.stack.3d.up"
        case .containers: "shippingbox"
        case .images: "opticaldisc"
        case .builds: "hammer"
        case .volumes: "externaldrive"
        case .networks: "network"
        case .machines: "desktopcomputer"
        case .system: "gearshape.2"
        }
    }

}

struct RootView: View {
    let reloadRuntimeSession: @MainActor () async -> Void
    @Environment(RuntimeSession.self) private var session
    @Environment(RuntimeInstallerModel.self) private var runtimeInstaller
    @State private var selection: SidebarItem? = .containers
    @State private var updateBannerDismissed = false

    var body: some View {
        Group {
            // Runtime-missing replaces the whole shell with onboarding
            // (P1D) — an empty Containers/Images/System screen would leave
            // the user guessing why nothing loads (master plan §3 exit
            // criteria: "app survives CLI absence gracefully").
            if case .runtimeMissing = session.containers.phase {
                OnboardingView(
                    model: runtimeInstaller,
                    onRuntimeAvailable: reloadRuntimeSession
                )
            } else {
                VStack(spacing: 0) {
                    UpdateBanner(model: runtimeInstaller, isDismissed: $updateBannerDismissed)
                    shell
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(CapsulePalette.accent)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await runtimeInstaller.refresh()
                if case .runtimeMissing = session.containers.phase,
                   case .present = runtimeInstaller.runtimePresence {
                    await reloadRuntimeSession()
                }
            }
        }
    }

    private var shell: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(SidebarItem.allCases, selection: $selection) { item in
                    Label(item.title, systemImage: item.systemImage)
                        .tag(item)
                }
                .listStyle(.sidebar)

                Divider()

                Button {
                    selection = .system
                } label: {
                    RuntimeStatusIndicator(status: runtimeStatus)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Open runtime status and diagnostics")
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            switch selection ?? .containers {
            case .containers:
                ContainersView(session: session)
            case .images:
                ImagesView(session: session)
            case .system:
                SystemView(session: session)
            case .composeProjects:
                ComposeProjectsView(session: session)
            case .volumes:
                VolumesView(session: session)
            case .networks:
                NetworksView(session: session)
            case .builds:
                BuildsView(session: session)
            case .machines:
                MachinesView(session: session)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                RuntimeStatusIndicator(
                    status: runtimeStatus,
                    showsLabel: false
                )
            }
        }
    }

    private var runtimeStatus: RuntimeStatusIndicator.Status {
        switch session.containers.phase {
        case .connecting:
            .checking
        case .loaded:
            .running
        case .runtimeMissing, .unavailable:
            .unavailable
        }
    }
}
