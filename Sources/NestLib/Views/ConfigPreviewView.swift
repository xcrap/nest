import SwiftUI

public struct ConfigPreviewView: View {
    @EnvironmentObject private var store: SiteStore
    @EnvironmentObject private var processController: ProcessController
    @EnvironmentObject private var documents: ConfigDocumentStore
    @State private var selectedConfig: ConfigFile = .caddyfile
    @State private var confirmDiscard = false

    enum ConfigFile: String, CaseIterable, Identifiable {
        case caddyfile = "Caddyfile", cloudflared = "cloudflared", security = "security.conf"
        case snippet = "php-app", overrides = "Overrides", php = "php.ini", database = "MariaDB"
        var id: String { rawValue }
        var generated: Bool { self == .caddyfile || self == .cloudflared }
    }
    public init() {}
    private var path: String {
        switch selectedConfig {
        case .caddyfile: return store.settings.caddyConfigDirectory + "/Caddyfile"
        case .cloudflared: return store.settings.cloudflareSettings.configPath
        case .security: return store.settings.caddyConfigDirectory + "/security.conf"
        case .snippet: return store.settings.caddyConfigDirectory + "/snippets/php-app"
        case .overrides: return store.settings.caddyConfigDirectory + "/overrides/custom.caddy"
        case .php: return store.settings.runtimePaths.phpIniPath.isEmpty ? "/opt/homebrew/etc/php.ini" : store.settings.runtimePaths.phpIniPath
        case .database: return "/opt/homebrew/etc/my.cnf"
        }
    }
    private var dirty: Bool { documents.drafts[path]?.dirty ?? false }
    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Configuration file", selection: $selectedConfig) {
                    ForEach(ConfigFile.allCases) { Text($0.rawValue).tag($0) }
                }.frame(maxWidth: 260).disabled(documents.busy)
                Text(dirty ? "Unsaved changes" : "").font(.caption).foregroundStyle(.orange)
                Spacer()
                if !selectedConfig.generated {
                    Menu("Recovery") {
                        Button("Restore Previous Version") { documents.restoreBackup(path: path) }
                            .disabled(!FileManager.default.fileExists(atPath: ConfigurationService.backupPath(for: path)))
                        Button("Discard & Reload", role: .destructive) { confirmDiscard = true }
                    }
                    Button(selectedConfig == .php || selectedConfig == .database ? "Save" : "Save & Apply", action: save)
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(documents.busy || documents.drafts[path] == nil)
                }
            }.padding(12).background(.bar)
            HStack {
                Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Spacer()
            }.padding(.horizontal, 12).padding(.vertical, 6)
            if selectedConfig.generated {
                Text("Generated from your sites and routes. Edit those records to change routing; use Overrides for custom Caddy configuration.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            if let error = documents.error { Text(error).foregroundStyle(.red).textSelection(.enabled).padding(8) }
            if let message = documents.message { Text(message).foregroundStyle(.secondary).padding(8) }
            Divider()
            if selectedConfig.generated {
                ScrollView([.vertical, .horizontal]) {
                    Text(documents.drafts[path]?.content ?? "").font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
                }
            } else {
                TextEditor(text: Binding(get: { documents.drafts[path]?.content ?? "" }, set: { documents.edit(path: path, content: $0) }))
                    .font(.system(.callout, design: .monospaced)).disabled(documents.busy)
                    .accessibilityLabel("\(selectedConfig.rawValue) configuration editor")
            }
        }
        .task(id: path) {
            if selectedConfig.generated { documents.discard(path: path) }
            else { documents.load(path: path) }
        }
        .alert("Discard unsaved changes?", isPresented: $confirmDiscard) {
            Button("Discard & Reload", role: .destructive) { documents.discard(path: path) }
            Button("Cancel", role: .cancel) {}
        }
    }
    private func save() {
        let target = path
        let config = selectedConfig
        let settings = store.settings
        let running = processController.frankenphpRunning
        Task {
            await documents.save(path: target) { content in
                if config == .security || config == .snippet || config == .overrides {
                    return try await ConfigurationService.shared.saveCaddySupport(content: content, path: target, settings: settings, running: running)
                }
                try await ConfigurationService.shared.save(content: content, path: target)
                return "Saved • restart \(config == .php ? "FrankenPHP" : "MariaDB") to apply."
            }
        }
    }
}
