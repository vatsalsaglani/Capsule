import AppCore
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
    @State private var selection: SidebarItem? = .containers

    var body: some View {
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
