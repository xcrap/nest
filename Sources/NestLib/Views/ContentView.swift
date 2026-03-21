import SwiftUI

public enum SidebarItem: String, CaseIterable, Identifiable {
    case sites = "Sites"
    case runtimePaths = "Runtime Paths"
    case config = "Configuration"
    case environment = "Environment"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .sites: return "globe"
        case .runtimePaths: return "gearshape.2"
        case .config: return "doc.text"
        case .environment: return "stethoscope"
        }
    }
}

public struct ContentView: View {
    @EnvironmentObject var store: SiteStore
    @EnvironmentObject var processController: ProcessController
    @State private var selection: SidebarItem? = .sites
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    public init() {}

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                List(SidebarItem.allCases, selection: $selection) { item in
                    Label(item.rawValue, systemImage: item.icon)
                        .tag(item)
                }
                .listStyle(.sidebar)

                Divider()

                // Services status footer
                VStack(spacing: 6) {
                    statusPill(
                        "FrankenPHP",
                        running: processController.frankenphpRunning
                    )
                    statusPill(
                        "MariaDB",
                        running: processController.mariadbRunning
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            Group {
                switch selection {
                case .sites:
                    SitesView()
                case .runtimePaths:
                    RuntimePathsView()
                case .config:
                    ConfigPreviewView()
                case .environment:
                    EnvironmentChecksView()
                case nil:
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation {
                        columnVisibility = columnVisibility == .detailOnly ? .automatic : .detailOnly
                    }
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .keyboardShortcut("b", modifiers: .command)
                .help("Toggle Sidebar (Cmd+B)")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bird")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.quaternary)
            Text("Select a section")
                .font(.title3)
                .foregroundStyle(.tertiary)
        }
    }

    private func statusPill(_ name: String, running: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(running ? Color.green : Color.secondary.opacity(0.25))
                .frame(width: 6, height: 6)
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(running ? "On" : "Off")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(running ? .green : .secondary)
        }
    }
}
