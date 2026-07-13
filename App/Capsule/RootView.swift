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

    /// Milestone that delivers the screen (docs/ROADMAP.md).
    var milestone: String {
        switch self {
        case .containers, .images, .system: "M1"
        case .composeProjects: "M2"
        case .volumes, .networks: "M3"
        case .builds, .machines: "M3"
        }
    }
}

struct RootView: View {
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
                OnboardingView(model: runtimeInstaller)
            } else {
                VStack(spacing: 0) {
                    UpdateBanner(model: runtimeInstaller, isDismissed: $updateBannerDismissed)
                    shell
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await runtimeInstaller.refresh() }
        }
    }

    private var shell: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.systemImage)
                    .tag(item)
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
            case let item:
                PlaceholderView(item: item)
            }
        }
    }
}

struct PlaceholderView: View {
    let item: SidebarItem

    var body: some View {
        ContentUnavailableView {
            Label(item.title, systemImage: item.systemImage)
        } description: {
            Text("Arriving in \(item.milestone) — see docs/ROADMAP.md.")
        }
        .navigationTitle(item.title)
    }
}
