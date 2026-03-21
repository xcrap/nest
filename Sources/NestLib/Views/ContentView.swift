import SwiftUI

public enum SidebarItem: String, CaseIterable, Identifiable {
    case sites = "Sites"
    case runtimePaths = "Runtime Paths"
    case config = "Configuration"
    case logs = "Logs"
    case environment = "Environment"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .sites: return "globe"
        case .runtimePaths: return "gearshape.2"
        case .config: return "doc.text"
        case .logs: return "doc.text.magnifyingglass"
        case .environment: return "stethoscope"
        }
    }
}

public struct ContentView: View {
    @EnvironmentObject var store: SiteStore
    @EnvironmentObject var processController: ProcessController
    @State private var selection: SidebarItem? = .sites

    public init() {}

    public var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(SidebarItem.allCases, selection: $selection) { item in
                    Label {
                        Text(item.rawValue)
                    } icon: {
                        Image(systemName: item.icon)
                            .foregroundStyle(.primary)
                    }
                    .tag(item)
                }
                .listStyle(.sidebar)

                Divider()

                VStack(spacing: 8) {
                    serviceRow(
                        "FrankenPHP",
                        running: processController.frankenphpRunning,
                        onToggle: {
                            if processController.frankenphpRunning {
                                processController.stopFrankenPHP()
                            } else {
                                startFrankenPHP()
                            }
                        }
                    )
                    serviceRow(
                        "MariaDB",
                        running: processController.mariadbRunning,
                        onToggle: {
                            if processController.mariadbRunning {
                                processController.stopMariaDB()
                            } else {
                                let paths = store.settings.runtimePaths
                                processController.startMariaDB(serverBinary: paths.mariadbServer)
                            }
                        }
                    )
                }
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
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
                case .logs:
                    LogsView()
                case .environment:
                    EnvironmentChecksView()
                case nil:
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "b" {
                    NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
                    return nil
                }
                return event
            }
        }
    }

    private func serviceRow(_ name: String, running: Bool, onToggle: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(running ? Color.green : Color.red.opacity(0.4))
                .frame(width: 7, height: 7)
            Text(name)
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer()
            Button(running ? "Stop" : "Start") {
                onToggle()
            }
            .font(.callout)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(running ? .red : .green)
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

    private func startFrankenPHP() {
        let paths = store.settings.runtimePaths
        guard !paths.frankenphpBinary.isEmpty else { return }
        let renderer = ConfigRenderer(
            configDirectory: store.settings.caddyConfigDirectory,
            frankenphpLogPath: paths.frankenphpLog
        )
        try? renderer.writeAll(sites: store.sites)
        processController.startFrankenPHP(binary: paths.frankenphpBinary, caddyfilePath: renderer.caddyfilePath)
    }
}
