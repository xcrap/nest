import SwiftUI

public struct ConfigPreviewView: View {
    @EnvironmentObject var store: SiteStore
    @State private var selectedConfig: ConfigFile = .caddyfile
    @State private var regenerated = false

    enum ConfigFile: String, CaseIterable, Identifiable {
        case caddyfile = "Caddyfile"
        case securityConf = "security.conf"
        case phpAppSnippet = "php-app snippet"
        case mariadbCnf = "mariadb.cnf"

        var id: String { rawValue }
    }

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Configuration")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                if regenerated {
                    Text("Written to disk")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
                Button("Regenerate & Write") {
                    writeConfig()
                }
            }
            .padding()

            Divider()

            Picker("File", selection: $selectedConfig) {
                ForEach(ConfigFile.allCases) { file in
                    Text(file.rawValue).tag(file)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            ScrollView {
                Text(configContent)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding()
        }
    }

    private var renderer: ConfigRenderer {
        ConfigRenderer(
            configDirectory: store.settings.configDirectory,
            logDirectory: store.settings.runtimePaths.logDirectory
        )
    }

    private var configContent: String {
        switch selectedConfig {
        case .caddyfile:
            return renderer.render(sites: store.sites)
        case .securityConf:
            return renderer.securityConf
        case .phpAppSnippet:
            return renderer.phpAppSnippet
        case .mariadbCnf:
            return mariadbConfig
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
        regenerated = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { regenerated = false }
    }
}
