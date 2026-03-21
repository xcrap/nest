import SwiftUI

public struct ConfigPreviewView: View {
    @EnvironmentObject var store: SiteStore
    @State private var selectedConfig: ConfigFile = .caddyfile
    @State private var editedContent: String = ""
    @State private var saved = false

    enum ConfigFile: String, CaseIterable, Identifiable {
        case caddyfile = "Caddyfile"
        case securityConf = "security.conf"
        case phpAppSnippet = "php-app"
        case phpIni = "php.ini"
        case myCnf = "MariaDB"

        var id: String { rawValue }

        var filePath: String {
            switch self {
            case .caddyfile: return "/opt/homebrew/etc/Caddyfile"
            case .securityConf: return "/opt/homebrew/etc/security.conf"
            case .phpAppSnippet: return "/opt/homebrew/etc/snippets/php-app"
            case .phpIni: return "/opt/homebrew/etc/php.ini"
            case .myCnf: return "/opt/homebrew/etc/my.cnf"
            }
        }
    }

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            configToolbar
            Divider()
            editorArea
        }
        .onAppear { loadContent() }
        .onChange(of: selectedConfig) { _ in loadContent() }
    }

    private var configToolbar: some View {
        HStack(spacing: 0) {
            ForEach(ConfigFile.allCases) { file in
                configTab(file)
            }

            Spacer()

            Text(selectedConfig.filePath)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.trailing, 8)

            if saved {
                Text("Saved")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .transition(.opacity)
                    .padding(.trailing, 6)
            }

            Button("Save") {
                saveContent()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
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
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(selectedConfig == file ? Color.accentColor.opacity(0.12) : Color.clear)
                )
                .foregroundStyle(selectedConfig == file ? Color.accentColor : Color.secondary)
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
        let path = selectedConfig.filePath
        if let onDisk = try? String(contentsOfFile: path, encoding: .utf8) {
            editedContent = onDisk
        } else {
            // Fall back to generated defaults for Caddy files
            switch selectedConfig {
            case .caddyfile:
                editedContent = renderer.render(sites: store.sites)
            case .securityConf:
                editedContent = renderer.securityConf
            case .phpAppSnippet:
                editedContent = renderer.phpAppSnippet
            case .phpIni:
                editedContent = "; php.ini for FrankenPHP\n; Place PHP configuration directives here.\n"
            case .myCnf:
                editedContent = "[client-server]\n\n!includedir /opt/homebrew/etc/my.cnf.d\n"
            }
        }
    }

    private func saveContent() {
        let path = selectedConfig.filePath

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
}
