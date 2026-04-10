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
            header
            Divider()

            ScrollView {
                VStack(spacing: 18) {
                    essentialsCard
                    advancedCard
                    serviceCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
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

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cloudflare")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Keep the tunnel essentials up front. The rest stays available when you need it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                Button("Import Settings...") {
                    importSettings = true
                }
                Button("Export Settings...") {
                    exportSettings = true
                }
            } label: {
                Label("Transfer", systemImage: "arrow.left.arrow.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Auto-Detect") {
                cloudflareSettings = CloudflareSettings.detectDefaults()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Save") {
                persistSettings()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var essentialsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Essentials")
                        .font(.headline)
                    Text("These are the values you are most likely to touch.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

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

            HStack(spacing: 18) {
                readinessBadge(
                    title: "Tunnel Service",
                    ready: cloudflareSettings.hasLocalConfiguration
                )
                readinessBadge(
                    title: "DNS API",
                    ready: cloudflareSettings.hasAPIConfiguration
                )
                Spacer()
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                VStack(alignment: .leading, spacing: 2) {
                    Text("Advanced Tunnel & DNS Configuration")
                        .font(.headline)
                    Text("Only needed when you are moving the setup to another machine or fixing Cloudflare metadata.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var serviceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tunnel Service")
                        .font(.headline)
                    Text("Write config, push remote changes, and control the persistent cloudflared service.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                serviceStatus
            }

            HStack(spacing: 10) {
                Button("Write Config") {
                    persistSettings()
                    writeTunnelConfig()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Sync Cloudflare") {
                    persistSettings()
                    syncTunnelConfig()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(processController.cloudflaredRunning ? "Stop Cloudflared" : "Start Cloudflared") {
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

            if let error = processController.cloudflaredError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var serviceStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(processController.cloudflaredRunning ? Color.green : Color.secondary.opacity(0.25))
                .frame(width: 8, height: 8)
            Text(processController.cloudflaredRunning ? "Cloudflared Running" : "Cloudflared Stopped")
                .font(.callout)
                .foregroundStyle(processController.cloudflaredRunning ? .green : .secondary)
        }
    }

    private func readinessBadge(title: String, ready: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ready ? .green : .orange)
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
                    statusMessage = "Tunnel config pushed to Cloudflare."
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
