import SwiftUI

public struct TunnelsView: View {
    @EnvironmentObject private var store: SiteStore

    @State private var editingRoute: TunnelRoute?
    @State private var showAddSheet = false
    @State private var routePendingDeletion: TunnelRoute?
    @State private var searchText = ""
    @State private var hoveredRouteId: String?

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
        VStack(spacing: 0) {
            toolbar
            Divider()

            if store.tunnelRoutes.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredRoutes) { route in
                            TunnelRouteRow(
                                route: route,
                                isHovered: hoveredRouteId == route.id,
                                onEdit: { editingRoute = route },
                                onDelete: { routePendingDeletion = route }
                            )
                            .onHover { h in
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    hoveredRouteId = h ? route.id : nil
                                }
                            }
                            if route.id != filteredRoutes.last?.id {
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

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.callout)
                TextField("Filter...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4, style: .continuous))

            Spacer()

            Text("\(activeCount)/\(store.tunnelRoutes.count) active")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button {
                showAddSheet = true
            } label: {
                Image(systemName: "plus")
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

private struct TunnelRouteRow: View {
    @EnvironmentObject private var store: SiteStore

    let route: TunnelRoute
    let isHovered: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var hoveredAction: String?

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

            Text("\(route.localDomain):\(route.originPort)")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 0) {
                rowAction(icon: "pencil", help: "Edit") { onEdit() }
                rowAction(icon: "trash", help: "Delete") { onDelete() }
            }
            .opacity(isHovered ? 1 : 0)

            Toggle("", isOn: Binding(
                get: { route.active },
                set: { newValue in
                    var updated = route
                    updated.active = newValue
                    store.updateTunnelRoute(updated)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Edit Route") { onEdit() }
            Button(route.active ? "Disable" : "Enable") {
                var updated = route
                updated.active.toggle()
                store.updateTunnelRoute(updated)
            }
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
    }
}
