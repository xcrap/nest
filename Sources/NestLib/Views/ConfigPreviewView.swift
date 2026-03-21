import SwiftUI

public struct ConfigPreviewView: View {
    @EnvironmentObject var store: SiteStore
    @State private var selectedConfig: ConfigFile = .caddyfile
    @State private var regenerated = false

    enum ConfigFile: String, CaseIterable, Identifiable {
        case caddyfile = "Caddyfile"
        case securityConf = "security.conf"
        case phpAppSnippet = "php-app"
        case mariadbCnf = "mariadb.cnf"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .caddyfile: return "server.rack"
            case .securityConf: return "lock.shield"
            case .phpAppSnippet: return "chevron.left.forwardslash.chevron.right"
            case .mariadbCnf: return "cylinder"
            }
        }
    }

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            configHeader
            Divider()
            configTabBar
            Divider()
            codeArea
        }
    }

    private var configHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Configuration")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("Preview generated config files for FrankenPHP and MariaDB.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if regenerated {
                Label("Written", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
            Button {
                writeConfig()
            } label: {
                Label("Write to Disk", systemImage: "square.and.arrow.down")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var configTabBar: some View {
        HStack(spacing: 0) {
            ForEach(ConfigFile.allCases) { file in
                configTabButton(file)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func configTabButton(_ file: ConfigFile) -> some View {
        Button {
            selectedConfig = file
        } label: {
            HStack(spacing: 5) {
                Image(systemName: file.icon)
                    .font(.caption2)
                Text(file.rawValue)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selectedConfig == file ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .foregroundStyle(selectedConfig == file ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private var codeArea: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(configContent)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var renderer: ConfigRenderer {
        ConfigRenderer(
            configDirectory: store.settings.configDirectory,
            logDirectory: store.settings.runtimePaths.logDirectory
        )
    }

    private var configContent: String {
        switch selectedConfig {
        case .caddyfile: return renderer.render(sites: store.sites)
        case .securityConf: return renderer.securityConf
        case .phpAppSnippet: return renderer.phpAppSnippet
        case .mariadbCnf: return mariadbConfig
        }
    }

    private var mariadbConfig: String {
        let appSupport = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first ?? ""
        let dataDir = (appSupport as NSString).appendingPathComponent("Nest/data/mariadb")
        let socketPath = (appSupport as NSString).appendingPathComponent("Nest/run/mariadb.sock")
        let logPath = (appSupport as NSString).appendingPathComponent("Nest/logs/mariadb.log")
        return """
        [mysqld]
        datadir=\(dataDir)
        socket=\(socketPath)
        port=3306
        log-error=\(logPath)
        bind-address=127.0.0.1
        skip-networking=0
        """
    }

    private func writeConfig() {
        try? renderer.writeAll(sites: store.sites)
        withAnimation { regenerated = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { regenerated = false }
        }
    }
}
