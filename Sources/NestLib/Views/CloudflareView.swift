import SwiftUI
import UniformTypeIdentifiers

public struct CloudflareView: View {
    @EnvironmentObject var store: SiteStore
    @EnvironmentObject var processController: ProcessController

    @State private var cloudflareSettings = CloudflareSettings()
    @State private var statusMessage: String?
    @State private var exportSettings = false
    @State private var importSettings = false
    @State private var showAdvancedSettings = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    essentialsCard
                    advancedCard
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
        .onAppear {
            cloudflareSettings = store.settings.cloudflareSettings
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

            Button("Auto-Detect") {
                cloudflareSettings = CloudflareSettings.detectDefaults()
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
                settingField("Tunnel Name", text: $cloudflareSettings.tunnelName)
                VStack(alignment: .leading, spacing: 6) {
                    Text("API Token")
                        .font(.callout)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    SecureField("cfut_...", text: $cloudflareSettings.apiToken)
                        .textFieldStyle(.roundedBorder)
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
                        settingField("Tunnel ID", text: $cloudflareSettings.tunnelId)
                        settingField("Tunnel Domain", text: $cloudflareSettings.tunnelDomain)
                    }
                    HStack(spacing: 12) {
                        settingField("Zone ID", text: $cloudflareSettings.zoneId)
                        settingField("Account ID", text: $cloudflareSettings.accountId)
                    }
                    HStack(spacing: 12) {
                        settingField("Credentials File", text: $cloudflareSettings.credentialsFilePath)
                        settingField("cloudflared Config", text: $cloudflareSettings.configPath)
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
                Button("Write Config") {
                    persistSettings()
                    writeTunnelConfig()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Push to Cloudflare") {
                    persistSettings()
                    syncTunnelConfig()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Writes the local tunnel config, then pushes the generated ingress rules to Cloudflare.")

                Button(processController.cloudflaredRunning ? "Stop" : "Start") {
                    persistSettings()
                    if processController.cloudflaredRunning {
                        processController.stopCloudflared()
                    } else {
                        writeTunnelConfig()
                        processController.startCloudflared(settings: store.settings)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(processController.cloudflaredRunning ? .red : .green)
            }

            Text("Write Config updates the local cloudflared config on this Mac. Push to Cloudflare also sends the generated tunnel routes to Cloudflare's API.")
                .font(.caption)
                .foregroundStyle(.secondary)

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

    private func persistSettings() {
        store.settings.cloudflareSettings = cloudflareSettings
        store.saveSettings()
    }

    private func writeTunnelConfig() {
        do {
            let renderer = TunnelConfigRenderer(settings: cloudflareSettings)
            try renderer.writeConfig(routes: store.tunnelRoutes, sites: store.sites, projects: store.appProjects)
            statusMessage = "cloudflared config written to \(cloudflareSettings.configPath)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func syncTunnelConfig() {
        writeTunnelConfig()
        Task {
            do {
                try await CloudflareService.pushTunnelConfiguration(
                    settings: cloudflareSettings,
                    routes: store.tunnelRoutes,
                    sites: store.sites,
                    projects: store.appProjects
                )
                await MainActor.run {
                    statusMessage = "Tunnel routes pushed to Cloudflare."
                }
            } catch {
                await MainActor.run {
                    statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func handleSettingsImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let data = try Data(contentsOf: url)
            try store.importCloudflareSettings(from: data)
            cloudflareSettings = store.settings.cloudflareSettings
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
