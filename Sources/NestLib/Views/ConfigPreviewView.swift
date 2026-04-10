import SwiftUI

public struct ConfigPreviewView: View {
    @EnvironmentObject var store: SiteStore
    @State private var selectedConfig: ConfigFile = .caddyfile
    @State private var editedContent: String = ""
    @State private var saved = false

    enum ConfigFile: String, CaseIterable, Identifiable {
        case caddyfile = "Caddyfile"
        case cloudflared = "cloudflared"
        case securityConf = "security.conf"
        case phpAppSnippet = "php-app"
        case phpIni = "php.ini"
        case myCnf = "MariaDB"

        var id: String { rawValue }

        var filePath: String {
            switch self {
            case .caddyfile: return "/opt/homebrew/etc/Caddyfile"
            case .cloudflared: return CloudflareSettings.detectDefaults().configPath
            case .securityConf: return "/opt/homebrew/etc/security.conf"
            case .phpAppSnippet: return "/opt/homebrew/etc/snippets/php-app"
            case .phpIni: return "/opt/homebrew/etc/php.ini"
            case .myCnf: return "/opt/homebrew/etc/my.cnf"
            }
        }
    }

    public init() {}

    /// Returns the effective file path for a config, using the detected
    /// php.ini path from RuntimePaths instead of the hardcoded fallback.
    private func effectivePath(for config: ConfigFile) -> String {
        if config == .phpIni {
            let detected = store.settings.runtimePaths.phpIniPath
            return detected.isEmpty ? config.filePath : detected
        }
        if config == .cloudflared {
            let configured = store.settings.cloudflareSettings.configPath
            return configured.isEmpty ? config.filePath : configured
        }
        return config.filePath
    }

    public var body: some View {
        VStack(spacing: 0) {
            configToolbar
            Divider()
            editorArea
        }
        .onAppear { loadContent() }
        .onChange(of: selectedConfig) { loadContent() }
    }

    private var configToolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(ConfigFile.allCases) { file in
                    configTab(file)
                }
            }

            Spacer()

            Text(effectivePath(for: selectedConfig))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)

            if saved {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            Button {
                saveContent()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func configTab(_ file: ConfigFile) -> some View {
        Button {
            selectedConfig = file
        } label: {
            Text(file.rawValue)
                .font(.callout)
                .fontWeight(selectedConfig == file ? .semibold : .regular)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selectedConfig == file ? Color.primary.opacity(0.1) : Color.clear)
                )
                .foregroundStyle(selectedConfig == file ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }

    private var editorArea: some View {
        TextEditor(text: $editedContent)
            .font(.system(.callout, design: .monospaced))
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor))
    }

    private func loadContent() {
        let path = effectivePath(for: selectedConfig)
        if let onDisk = try? String(contentsOfFile: path, encoding: .utf8) {
            editedContent = onDisk
        } else {
            // Fall back to generated defaults for Caddy files
            switch selectedConfig {
            case .caddyfile:
                editedContent = renderer.render(sites: store.sites)
            case .cloudflared:
                editedContent = tunnelRenderer.render(routes: store.tunnelRoutes, sites: store.sites, projects: store.appProjects)
            case .securityConf:
                editedContent = renderer.securityConf
            case .phpAppSnippet:
                editedContent = renderer.phpAppSnippet
            case .phpIni:
                editedContent = "; php.ini for FrankenPHP\n; Place PHP configuration directives here.\n\n[PHP]\nerror_reporting = E_ALL & ~E_DEPRECATED\nlog_errors = On\nerror_log = php_errors.log\n"
            case .myCnf:
                editedContent = "[client-server]\n\n!includedir /opt/homebrew/etc/my.cnf.d\n"
            }
        }
    }

    private func saveContent() {
        let path = effectivePath(for: selectedConfig)

        // Ensure parent directory exists
        let parentDir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        try? editedContent.write(toFile: path, atomically: true, encoding: .utf8)
        withAnimation { saved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { saved = false }
        }
    }

    private var renderer: ConfigRenderer {
        ConfigRenderer(
            configDirectory: store.settings.caddyConfigDirectory,
            frankenphpLogPath: store.settings.runtimePaths.frankenphpLog
        )
    }

    private var tunnelRenderer: TunnelConfigRenderer {
        TunnelConfigRenderer(settings: store.settings.cloudflareSettings)
    }
}
