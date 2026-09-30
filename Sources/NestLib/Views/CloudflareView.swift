import SwiftUI
import UniformTypeIdentifiers

public struct CloudflareView: View {
    @EnvironmentObject var store: SiteStore
    @EnvironmentObject var processController: ProcessController
    @EnvironmentObject var documents: ConfigDocumentStore

    @State private var statusMessage: String?
    @State private var exportSettings = false
    @State private var importSettings = false
    @State private var showAdvancedSettings = false
    @State private var confirmPush = false

    public init() {}

    /// Edits live in the shared document store until saved, so they survive tab switches.
    private var draft: Binding<CloudflareSettings> {
        Binding(
            get: { documents.cloudflareDraft ?? store.settings.cloudflareSettings },
            set: { documents.cloudflareDraft = $0 }
        )
    }

    private var cloudflareSettings: CloudflareSettings { draft.wrappedValue }

    private var hasUnsavedChanges: Bool {
        guard let pending = documents.cloudflareDraft else { return false }
        return NestValidation.normalizedCloudflareSettings(pending) != store.settings.cloudflareSettings
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    essentialsCard
                    advancedCard
                    validationCard
                    serviceCard
                }
                .padding(16)
            }

            Divider()

            footer
        }
        .fileExporter(
            isPresented: $exportSettings,
            document: CloudflareSettingsDocument(settings: cloudflareSettings),
            contentType: .json,
            defaultFilename: "nest-cloudflare-settings"
        ) { _ in }
        .fileImporter(isPresented: $importSettings, allowedContentTypes: [.json]) { result in
            handleSettingsImport(result)
        }
        .alert("Cloudflare Status", isPresented: .init(get: { statusMessage != nil }, set: { if !$0 { statusMessage = nil } })) {
            Button("OK") { statusMessage = nil }
        } message: {
            Text(statusMessage ?? "")
        }
        .alert("Push to Cloudflare?", isPresented: $confirmPush) {
            Button("Push") {
                guard persistSettings() else { return }
                syncTunnelConfig()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the tunnel's ingress rules on Cloudflare with Nest's active routes. Hostnames added only in the Cloudflare dashboard will be removed. WARP routing settings are kept.")
        }
        .onAppear {
            processController.refreshStatusSnapshot(settings: store.settings, projects: store.appProjects)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Import Settings...") { importSettings = true }
                Button("Export Settings...") { exportSettings = true }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Transfer Settings")

            Spacer()

            if hasUnsavedChanges {
                Text("Unsaved changes").font(.caption).foregroundStyle(.orange)
            }

            Button("Auto-Detect") {
                documents.cloudflareDraft = cloudflareSettings.mergingDetected(CloudflareSettings.detectDefaults())
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Save") { persistSettings() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Cards

    private var essentialsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Essentials")
                .font(.callout)
                .fontWeight(.semibold)

            HStack(spacing: 12) {
                settingField("Tunnel Name", text: draft.tunnelName)
                VStack(alignment: .leading, spacing: 6) {
                    Text("API Token")
                        .font(.callout)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    SecureField("Stored in Keychain", text: draft.apiToken)
                        .textFieldStyle(.roundedBorder)
                    Text("Stored in Keychain; excluded from exports.").font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 16) {
                readinessBadge(title: "Tunnel Service", ready: cloudflareSettings.hasLocalConfiguration)
                readinessBadge(title: "DNS API", ready: cloudflareSettings.hasAPIConfiguration)
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var advancedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup(isExpanded: $showAdvancedSettings) {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        settingField("Tunnel ID", text: draft.tunnelId)
                        settingField("Tunnel Domain", text: draft.tunnelDomain)
                    }
                    HStack(spacing: 12) {
                        settingField("Zone ID", text: draft.zoneId)
                        settingField("Account ID", text: draft.accountId)
                    }
                    HStack(spacing: 12) {
                        settingField("Credentials File", text: draft.credentialsFilePath)
                        settingField("cloudflared Config", text: draft.configPath)
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("Advanced")
                    .font(.callout)
                    .fontWeight(.semibold)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var serviceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tunnel Service")
                    .font(.callout)
                    .fontWeight(.semibold)
                Spacer()
                serviceStatus
            }

            HStack(spacing: 8) {
                Button("Apply Locally") {
                    guard persistSettings() else { return }
                    processController.applyTunnels(settings: store.settings, routes: store.tunnelRoutes, sites: store.sites, projects: store.appProjects)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Push to Cloudflare…") {
                    confirmPush = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Writes the local tunnel config, then pushes the generated ingress rules to Cloudflare.")

                Button(processController.cloudflaredRunning ? "Stop" : "Start") {
                    // Stopping never depends on the settings form being savable.
                    if processController.cloudflaredRunning {
                        processController.stopCloudflared()
                    } else {
                        guard persistSettings() else { return }
                        processController.applyTunnels(settings: store.settings, routes: store.tunnelRoutes, sites: store.sites, projects: store.appProjects, start: true)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(processController.cloudflaredRunning ? .red : .green)
            }

            .disabled(processController.isServiceBusy("Cloudflared"))

            Text("Apply Locally validates and saves routes, then restarts the running connector. Push to Cloudflare also updates API ingress. Public reachability can be checked from Tunnels.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(processController.tunnelApplyState.label).font(.callout).textSelection(.enabled)

            if let error = processController.cloudflaredError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    @ViewBuilder
    private var validationCard: some View {
        let issues = TunnelConfigRenderer(settings: cloudflareSettings)
            .validationIssues(routes: store.tunnelRoutes, sites: store.sites, projects: store.appProjects)
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Configuration Issues")
                        .font(.callout)
                        .fontWeight(.semibold)
                }

                ForEach(issues, id: \.self) { issue in
                    Text(issue)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.orange.opacity(0.06))
                    .strokeBorder(Color.orange.opacity(0.15), lineWidth: 1)
            )
        }
    }

    // MARK: - Components

    private var serviceStatus: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(processController.cloudflaredRunning ? Color.green : Color.secondary.opacity(0.2))
                .frame(width: 8, height: 8)
            Text(processController.cloudflaredRunning ? "Running" : "Stopped")
                .font(.callout)
                .foregroundStyle(processController.cloudflaredRunning ? .green : .secondary)
        }
    }

    private func readinessBadge(title: String, ready: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ready ? .green : .orange)
                .font(.callout)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func settingField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.callout)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    @discardableResult
    private func persistSettings() -> Bool {
        let normalized = NestValidation.normalizedCloudflareSettings(cloudflareSettings)
        let saved = store.replaceCloudflareSettings(normalized)
        if saved {
            documents.cloudflareDraft = nil
        } else {
            documents.cloudflareDraft = normalized
            statusMessage = store.saveError(.settings)
        }
        return saved
    }

    private func syncTunnelConfig() {
        processController.applyTunnels(settings: store.settings, routes: store.tunnelRoutes, sites: store.sites, projects: store.appProjects, push: true)
    }

    private func handleSettingsImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        // Nest is not sandboxed, so the URL is usually readable without a security scope.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            try store.importCloudflareSettings(from: data)
            documents.cloudflareDraft = nil
            statusMessage = "Cloudflare settings imported."
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

// MARK: - Export Document

private struct CloudflareSettingsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let settings: CloudflareSettings

    init(settings: CloudflareSettings) {
        self.settings = settings
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        settings = try JSONDecoder().decode(CloudflareSettings.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        return FileWrapper(regularFileWithContents: data)
    }
}
