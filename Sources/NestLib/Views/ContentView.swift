import SwiftUI

public enum SidebarItem: String, CaseIterable, Identifiable {
    case sites = "Sites"
    case runtimePaths = "Runtime Paths"
    case config = "Configuration"
    case migration = "Migration"
    case environment = "Environment"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .sites: return "globe"
        case .runtimePaths: return "wrench.and.screwdriver"
        case .config: return "doc.text"
        case .migration: return "square.and.arrow.down"
        case .environment: return "checkmark.shield"
        }
    }
}

public struct ContentView: View {
    @State private var selection: SidebarItem? = .sites

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch selection {
            case .sites:
                SitesView()
            case .runtimePaths:
                RuntimePathsView()
            case .config:
                ConfigPreviewView()
            case .migration:
                MigrationView()
            case .environment:
                EnvironmentChecksView()
            case nil:
                Text("Select an item from the sidebar.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
