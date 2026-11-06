import SwiftUI

public struct TunnelsView: View {
    @EnvironmentObject private var store: SiteStore
    @EnvironmentObject private var processController: ProcessController

    @State private var editingRoute: TunnelRoute?
    @State private var showAddSheet = false
    @State private var routePendingDeletion: TunnelRoute?
    @State private var searchText = ""

    public init() {}

    private var filteredRoutes: [TunnelRoute] {
        let sorted = store.tunnelRoutes.sorted { $0.publicHostname.localizedCaseInsensitiveCompare($1.publicHostname) == .orderedAscending }
        if searchText.isEmpty { return sorted }
        let q = searchText.lowercased()
        return sorted.filter {
            $0.publicHostname.lowercased().contains(q)
            || $0.localDomain.lowercased().contains(q)
            || $0.subdomain.lowercased().contains(q)
        }
    }

    private var activeCount: Int {
        store.tunnelRoutes.filter(\.active).count
    }

    public var body: some View {
        let routes = filteredRoutes
        let lastID = routes.last?.id
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(processController.tunnelApplyState.label).font(.callout).textSelection(.enabled)
                    Text("Changes sync automatically when saved.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if case .applied = processController.tunnelApplyState {
                    Button("Check All") { for route in store.tunnelRoutes where route.active { processController.checkRoute(route) } }
                } else {
                    Button("Sync Now") {
                        processController.applyTunnels(store: store,
                            push: store.settings.cloudflareSettings.hasAPIConfiguration, start: store.tunnelRoutes.contains(where: \.active))
                    }.disabled(processController.isServiceBusy("Cloudflared") || store.lastSaveError != nil)
                }
            }.padding(12)
            if processController.needsDNSRefresh || processController.refreshingDNS || processController.dnsRefreshError != nil {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Public DNS is ready, but this Mac cannot find the address.").font(.callout)
                        Text(processController.dnsRefreshError ?? "Refresh the Mac’s DNS cache, then Nest will check again. macOS will ask for an administrator password.")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button(processController.refreshingDNS ? "Refreshing…" : "Refresh Mac DNS") {
                        processController.refreshMacDNS(routes: store.tunnelRoutes)
                    }.disabled(processController.refreshingDNS)
                }.padding(12).background(Color.orange.opacity(0.08))
            }
            Divider()

            if store.tunnelRoutes.isEmpty {
                emptyState
            } else if routes.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                let cloudflaredBusy = processController.isServiceBusy("Cloudflared")
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(routes) { route in
                            // Rows get plain values and are Equatable, so "Check All" re-renders
                            // only the row whose health changed instead of every row per update.
                            TunnelRouteRow(
                                route: route,
                                health: processController.routeHealth[route.id],
                                cloudflaredBusy: cloudflaredBusy,
                                onSetActive: { setActive(route, $0) },
                                onCheck: { processController.checkRoute(route) },
                                onEdit: { editingRoute = route },
                                onDelete: { routePendingDeletion = route }
                            )
                            .equatable()
                            if route.id != lastID {
                                Divider().padding(.leading, 36)
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            TunnelFormSheet(mode: .add)
        }
        .task {
            for route in store.tunnelRoutes where route.active && processController.routeHealth[route.id] == nil {
                processController.checkRoute(route)
            }
        }
        .sheet(item: $editingRoute) { route in
            TunnelFormSheet(mode: .edit(route))
        }
        .alert(
            "Delete Tunnel Route?",
            isPresented: .init(
                get: { routePendingDeletion != nil },
                set: { if !$0 { routePendingDeletion = nil } }
            ),
            actions: {
                Button("Delete", role: .destructive) {
                    if let routePendingDeletion {
                        store.deleteTunnelRoute(id: routePendingDeletion.id)
                    }
                    routePendingDeletion = nil
                }
                Button("Cancel", role: .cancel) {
                    routePendingDeletion = nil
                }
            },
            message: {
                if let routePendingDeletion {
                    Text("Remove \(routePendingDeletion.publicHostname) from tunnel configuration.")
                }
            }
        )
    }

    private func setActive(_ route: TunnelRoute, _ active: Bool) {
        var updated = route
        updated.active = active
        store.updateTunnelRoute(updated)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .accessibilityHidden(true)
                TextField("Filter...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .accessibilityLabel("Filter routes")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Label("Clear Filter", systemImage: "xmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4, style: .continuous))

            Spacer()

            Text("\(activeCount)/\(store.tunnelRoutes.count) enabled")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button {
                showAddSheet = true
            } label: {
                Label("Add Route", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("n", modifiers: .command)
            .help("Add Route (Cmd+N)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: "network")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.quaternary)
                Text("No tunnel routes yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Add Route") { showAddSheet = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Spacer()
        }
    }
}

// MARK: - Tunnel Route Row

private struct TunnelRouteRow: View, Equatable {
    let route: TunnelRoute
    let health: RouteHealth?
    let cloudflaredBusy: Bool
    let onSetActive: (Bool) -> Void
    let onCheck: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    /// Row-local so hovering redraws one row, not the whole list.
    @State private var isHovered = false
    @State private var hoveredAction: String?

    /// The closures only capture `route`, so comparing the values is enough.
    static func == (lhs: TunnelRouteRow, rhs: TunnelRouteRow) -> Bool {
        lhs.route == rhs.route && lhs.health == rhs.health && lhs.cloudflaredBusy == rhs.cloudflaredBusy
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(route.kind == .php ? "PHP" : "APP")
                .font(.caption2)
                .fontWeight(.semibold)
                .frame(width: 32)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(badgeColor.opacity(0.12))
                )
                .foregroundStyle(badgeColor)

            Text(route.publicHostname)
                .font(.system(.callout, design: .monospaced))
                .fontWeight(.medium)
                .lineLimit(1)
                .frame(width: 220, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.quaternary)

            Text(route.localDomain + ":" + String(route.originPort))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let health {
                Text(health.label).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(health.label)
            }

            HStack(spacing: 0) {
                rowAction(icon: "pencil", help: "Edit") { onEdit() }
                rowAction(icon: "trash", help: "Delete") { onDelete() }
            }

            Toggle("Enable \(route.publicHostname)", isOn: Binding(
                get: { route.active },
                set: { onSetActive($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(cloudflaredBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
        .contextMenu {
            Button("Check Reachability") { onCheck() }
                .disabled(!route.active || health == .checking)
            Button("Edit Route") { onEdit() }
            Button(route.active ? "Disable" : "Enable") { onSetActive(!route.active) }
            Divider()
            Button("Delete Route", role: .destructive) { onDelete() }
        }
    }

    private var badgeColor: Color {
        route.kind == .php ? .blue : .green
    }

    private func rowAction(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.callout)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(hoveredAction == icon ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hoveredAction == icon ? .primary : .secondary)
        .onHover { h in hoveredAction = h ? icon : nil }
        .help(help)
        .accessibilityLabel("\(help) \(route.publicHostname)")
    }
}
