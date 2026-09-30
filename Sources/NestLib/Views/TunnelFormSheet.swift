import SwiftUI

public enum TunnelFormMode: Identifiable {
    case add
    case edit(TunnelRoute)

    public var id: String {
        switch self {
        case .add: return "add"
        case .edit(let route): return route.id
        }
    }
}

public struct TunnelFormSheet: View {
    @EnvironmentObject var store: SiteStore
    @Environment(\.dismiss) private var dismiss

    public let mode: TunnelFormMode

    @State private var kind: TunnelRouteKind = .php
    @State private var subdomain = ""
    @State private var publicDomain = ""
    @State private var localDomain = ""
    @State private var originPort = "443"
    @State private var linkedSiteDomain = ""
    @State private var linkedProjectID = ""
    @State private var active = true
    @State private var errorMessage: String?

    public init(mode: TunnelFormMode) {
        self.mode = mode
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 520)
        .onAppear(perform: populate)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "Edit Tunnel Route" : "New Tunnel Route")
                    .font(.headline)
                Text("Routes are saved in Nest. Use Apply Changes on the Tunnels screen to apply them to cloudflared.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var form: some View {
        VStack(spacing: 16) {
            field("Route Type") {
                Picker("", selection: Binding(get: { kind }, set: { changeKind(to: $0) })) {
                    ForEach(TunnelRouteKind.allCases) { item in
                        Text(item.rawValue.uppercased()).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack(spacing: 12) {
                field("Subdomain") {
                    TextField("app", text: $subdomain)
                        .textFieldStyle(.roundedBorder)
                }

                field("Public Domain") {
                    TextField("example.com", text: $publicDomain)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if kind == .php {
                field("Linked Site") {
                    Picker("Linked Site", selection: $linkedSiteDomain) {
                        Text("Manual").tag("")
                        ForEach(store.sites.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { site in
                            Text(site.domain).tag(site.domain)
                        }
                    }
                    .onChange(of: linkedSiteDomain) {
                        if let site = store.sites.first(where: { $0.domain == linkedSiteDomain }) {
                            localDomain = site.domain
                        }
                    }
                }
            } else {
                field("Linked Project") {
                    Picker("Linked Project", selection: $linkedProjectID) {
                        Text("Manual").tag("")
                        ForEach(store.appProjects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { project in
                            Text(project.name).tag(project.id)
                        }
                    }
                    .onChange(of: linkedProjectID) {
                        if let project = store.appProjects.first(where: { $0.id == linkedProjectID }) {
                            localDomain = project.hostname
                            originPort = "\(project.port)"
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                field(kind == .php ? "Local Domain" : "Host Header") {
                    TextField(kind == .php ? "mysite.test" : "app.example.com", text: $localDomain)
                        .textFieldStyle(.roundedBorder)
                }

                field(kind == .php ? "HTTPS Port" : "Port") {
                    TextField(kind == .php ? "443" : "3999", text: $originPort)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Toggle("Active", isOn: $active)
                .toggleStyle(.switch)

            if let errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                    Spacer()
                }
            }
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(isEditing ? "Save Changes" : "Add Route") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(subdomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || publicDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || localDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(20)
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.callout)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Links, host and port from the other route type are never valid for the new one
    /// (e.g. a PHP route's 443 would send an app route to Caddy's TLS port).
    private func changeKind(to newKind: TunnelRouteKind) {
        guard newKind != kind else { return }
        kind = newKind
        linkedSiteDomain = ""
        linkedProjectID = ""
        localDomain = ""
        originPort = newKind == .php ? "443" : ""
    }

    private func populate() {
        switch mode {
        case .add:
            // Default to the domain the user already routes most, not a fixed one.
            let counts = Dictionary(grouping: store.tunnelRoutes.map(\.publicDomain).filter { !$0.isEmpty }, by: { $0 })
            publicDomain = counts.max { $0.value.count < $1.value.count }?.key ?? ""
        case .edit(let route):
            kind = route.kind
            subdomain = route.subdomain
            publicDomain = route.publicDomain
            localDomain = route.localDomain
            originPort = "\(route.originPort)"
            linkedSiteDomain = route.linkedSiteDomain ?? ""
            linkedProjectID = route.linkedProjectID ?? ""
            active = route.active
        }
    }

    private func save() {
        errorMessage = nil
        guard let parsedPort = Int(originPort), parsedPort > 0 else {
            errorMessage = "Port must be a valid number."
            return
        }

        let normalizedSubdomain = subdomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedPublicDomain = NestValidation.normalizedDomain(publicDomain)
        let normalizedLocalDomain = NestValidation.normalizedDomain(localDomain)
        let hostname = "\(normalizedSubdomain).\(normalizedPublicDomain)"
        let candidate = TunnelRoute(
            id: mode.id,
            kind: kind,
            subdomain: normalizedSubdomain,
            publicDomain: normalizedPublicDomain,
            localDomain: normalizedLocalDomain,
            originPort: parsedPort,
            active: active,
            linkedSiteDomain: linkedSiteDomain.isEmpty ? nil : linkedSiteDomain,
            linkedProjectID: linkedProjectID.isEmpty ? nil : linkedProjectID
        )

        let issues = NestValidation.tunnelRouteIssues(candidate)
        guard issues.isEmpty else {
            errorMessage = issues.joined(separator: " ")
            return
        }

        let duplicate = store.tunnelRoutes.contains {
            $0.publicHostname == hostname && $0.id != mode.id
        }
        if duplicate {
            errorMessage = "A tunnel route for '\(hostname)' already exists."
            return
        }

        switch mode {
        case .add:
            store.addTunnelRoute(
                TunnelRoute(
                    id: UUID().uuidString,
                    kind: kind,
                    subdomain: normalizedSubdomain,
                    publicDomain: normalizedPublicDomain,
                    localDomain: normalizedLocalDomain,
                    originPort: parsedPort,
                    active: active,
                    linkedSiteDomain: linkedSiteDomain.isEmpty ? nil : linkedSiteDomain,
                    linkedProjectID: linkedProjectID.isEmpty ? nil : linkedProjectID
                )
            )
        case .edit(var route):
            route.kind = kind
            route.subdomain = normalizedSubdomain
            route.publicDomain = normalizedPublicDomain
            route.localDomain = normalizedLocalDomain
            route.originPort = parsedPort
            route.active = active
            route.linkedSiteDomain = linkedSiteDomain.isEmpty ? nil : linkedSiteDomain
            route.linkedProjectID = linkedProjectID.isEmpty ? nil : linkedProjectID
            store.updateTunnelRoute(route)
        }

        dismiss()
    }
}
