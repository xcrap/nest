import SwiftUI

public struct TunnelsView: View {
    @EnvironmentObject private var store: SiteStore

    @State private var editingRoute: TunnelRoute?
    @State private var showAddSheet = false
    @State private var routePendingDeletion: TunnelRoute?

    public init() {}

    private var sortedRoutes: [TunnelRoute] {
        store.tunnelRoutes.sorted { $0.publicHostname.localizedCaseInsensitiveCompare($1.publicHostname) == .orderedAscending }
    }

    private var activeCount: Int {
        store.tunnelRoutes.filter(\.active).count
    }

    private var inactiveCount: Int {
        max(store.tunnelRoutes.count - activeCount, 0)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if sortedRoutes.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(sortedRoutes) { route in
                        TunnelRouteRow(
                            route: route,
                            onEdit: { editingRoute = route },
                            onDelete: { routePendingDeletion = route }
                        )
                    }
                }
                .listStyle(.inset)
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
                    Text("This will remove `\(routePendingDeletion.publicHostname)` from Nest's tunnel configuration.")
                }
            }
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tunnels")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("\(activeCount) active, \(inactiveCount) inactive")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                showAddSheet = true
            } label: {
                Label("Add Route", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "network")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.quaternary)
            Text("No tunnel routes yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Add Route") { showAddSheet = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Spacer()
        }
    }
}

private struct TunnelRouteRow: View {
    @EnvironmentObject private var store: SiteStore

    let route: TunnelRoute
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var destinationText: String {
        "\(route.localDomain):\(route.originPort)"
    }

    var body: some View {
        HStack(spacing: 12) {
            RouteKindBadge(kind: route.kind)

            VStack(alignment: .leading, spacing: 4) {
                Text(route.publicHostname)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
                    .lineLimit(1)

                Text(destinationText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Button("Edit", action: onEdit)
                .buttonStyle(.bordered)
                .controlSize(.small)

            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Toggle("Active", isOn: Binding(
                get: { route.active },
                set: { newValue in
                    var updated = route
                    updated.active = newValue
                    store.updateTunnelRoute(updated)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(route.active ? "Disable route" : "Enable route")
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Edit Route") { onEdit() }
            Button(route.active ? "Disable" : "Enable") {
                var updated = route
                updated.active.toggle()
                store.updateTunnelRoute(updated)
            }
            Divider()
            Button("Delete Route", role: .destructive) {
                onDelete()
            }
        }
        .onTapGesture(count: 2) {
            onEdit()
        }
    }
}

private struct RouteKindBadge: View {
    let kind: TunnelRouteKind

    private var kindColor: Color {
        kind == .php ? .blue : .green
    }

    var body: some View {
        Text(kind == .php ? "PHP" : "APP")
            .font(.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(kindColor.opacity(0.12))
            )
            .foregroundStyle(kindColor)
    }
}
