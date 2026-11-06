import SwiftUI

public enum SidebarItem: String, CaseIterable, Identifiable {
    case sites = "Sites"
    case projects = "Projects"
    case tunnels = "Tunnels"
    case dns = "DNS"
    case logs = "Logs"
    case settings = "Settings"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .sites: return "globe"
        case .projects: return "square.stack.3d.up"
        case .tunnels: return "network"
        case .dns: return "icloud"
        case .logs: return "doc.text.magnifyingglass"
        case .settings: return "gearshape"
        }
    }
}

public struct ContentView: View {
    @EnvironmentObject var store: SiteStore
    /// Not observed: only the sidebar service rows depend on service state, and they observe
    /// it themselves. Observing it here would re-render the whole window on every change.
    private let processController: ProcessController
    @SceneStorage("sidebarSelection") private var selection: SidebarItem = .sites

    public init(processController: ProcessController) {
        self.processController = processController
    }

    /// The sidebar list reports nil when the selection is cleared; keep the current section.
    private var listSelection: Binding<SidebarItem?> {
        Binding(get: { selection }, set: { if let item = $0 { selection = item } })
    }

    public var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(SidebarItem.allCases, selection: listSelection) { item in
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

                SidebarServicesView(store: store)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            Group {
                switch selection {
                case .sites:
                    SitesView()
                case .projects:
                    ProjectsView()
                case .tunnels:
                    TunnelsView()
                case .dns:
                    DNSView()
                case .logs:
                    LogsView()
                case .settings:
                    WorkspaceSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .focusedSceneValue(\.sidebarSelection, $selection)
        .onAppear {
            processController.markTunnelsPending(store: store)
        }
        .onChange(of: store.sites) {
            processController.applyCaddy(store: store)
            syncSavedTunnels()
        }
        .onChange(of: store.tunnelRoutes) { syncSavedTunnels() }
        .onChange(of: store.appProjects) {
            // Local `.test` domains are Caddy routes; edits that render the same Caddyfile are skipped.
            processController.applyCaddy(store: store)
            syncSavedTunnels()
        }
        .onChange(of: store.settings) {
            processController.markCaddyPending(store: store)
            syncSavedTunnels()
        }
        .safeAreaInset(edge: .bottom) {
            if let error = store.lastSaveError ?? store.credentialError ?? store.caddyConfigurationError ?? store.tunnelConfigurationError {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).padding(8)
            }
        }
    }

    private func syncSavedTunnels() {
        processController.markTunnelsPending(store: store, automaticallyApply: true)
    }
}

/// Start/stop rows for the services. The only part of the window that observes every
/// service status change.
private struct SidebarServicesView: View {
    @EnvironmentObject private var processController: ProcessController
    /// Read at action time only.
    let store: SiteStore

    var body: some View {
        VStack(spacing: 8) {
            serviceRow("FrankenPHP", running: processController.frankenphpRunning, error: processController.frankenphpError) {
                if processController.frankenphpRunning {
                    processController.stopFrankenPHP()
                } else {
                    processController.startFrankenPHP(store: store)
                }
            }
            serviceRow("Cloudflared", running: processController.cloudflaredRunning, error: processController.cloudflaredError) {
                if processController.cloudflaredRunning {
                    processController.stopCloudflared()
                } else {
                    processController.applyTunnels(store: store, start: true)
                }
            }
            serviceRow("MariaDB", running: processController.mariadbRunning, error: processController.mariadbError) {
                if processController.mariadbRunning {
                    processController.stopMariaDB()
                } else {
                    processController.startMariaDB(serverBinary: store.settings.runtimePaths.mariadbServer)
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private func serviceRow(_ name: String, running: Bool, error: String?, onToggle: @escaping () -> Void) -> some View {
        let busy = processController.isServiceBusy(name)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(running ? Color.green : Color.secondary.opacity(0.2)).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(name).font(.callout).lineLimit(1)
                    .accessibilityValue(running ? "Running" : "Stopped")
                Spacer()
                Button(busy ? "…" : (running ? "Stop" : "Start"), action: onToggle)
                    .font(.callout).buttonStyle(.bordered).controlSize(.small)
                    .disabled(busy)
                    .accessibilityLabel("\(running ? "Stop" : "Start") \(name)")
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }
}
