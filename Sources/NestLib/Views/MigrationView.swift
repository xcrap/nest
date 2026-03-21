import SwiftUI
import UniformTypeIdentifiers

public struct MigrationView: View {
    @EnvironmentObject var store: SiteStore
    @State private var showFilePicker = false
    @State private var showBundlePicker = false
    @State private var importMessages: [String] = []
    @State private var exportCommands: [String] = []

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Migration")
                    .font(.title2)
                    .fontWeight(.semibold)

                // Legacy Import
                GroupBox("Import Legacy Sites") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Import sites from a nest-sites.json file exported by the previous Electron+Go app.")
                            .foregroundStyle(.secondary)
                            .font(.callout)

                        Button("Choose File…") {
                            showFilePicker = true
                        }

                        ForEach(importMessages, id: \.self) { msg in
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(msg.contains("Error") || msg.contains("skipped") ? .orange : .secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                // Migration Bundle Import
                GroupBox("Import Migration Bundle") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Import from a migration bundle directory containing manifest.json, sites.json, and database dumps.")
                            .foregroundStyle(.secondary)
                            .font(.callout)

                        Button("Choose Bundle Folder…") {
                            showBundlePicker = true
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                // Database Export Assistant
                GroupBox("Database Export Assistant") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Run these commands to export your MariaDB databases before migrating.")
                            .foregroundStyle(.secondary)
                            .font(.callout)

                        Button("Generate Commands") {
                            let socketPath = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)
                                .first.map { ($0 as NSString).appendingPathComponent("Nest/run/mariadb.sock") }
                            exportCommands = MigrationService.exportCommands(
                                mysqldumpPath: store.settings.runtimePaths.mysqldump,
                                socketPath: socketPath
                            )
                        }

                        if !exportCommands.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(exportCommands, id: \.self) { cmd in
                                    Text(cmd)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(8)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
            .padding()
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.json]) { result in
            handleLegacyImport(result)
        }
        .fileImporter(isPresented: $showBundlePicker, allowedContentTypes: [.folder]) { result in
            handleBundleImport(result)
        }
    }

    private func handleLegacyImport(_ result: Result<URL, Error>) {
        importMessages = []
        guard case .success(let url) = result else {
            importMessages = ["Error: could not access file."]
            return
        }
        guard url.startAccessingSecurityScopedResource() else {
            importMessages = ["Error: permission denied."]
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let data = try? Data(contentsOf: url) else {
            importMessages = ["Error: could not read file."]
            return
        }

        do {
            let (imported, errors) = try store.importLegacySites(from: data)
            importMessages.append("Imported \(imported.count) site(s).")
            for error in errors {
                importMessages.append("Skipped: \(error.localizedDescription)")
            }
        } catch {
            importMessages.append("Error: \(error.localizedDescription)")
        }
    }

    private func handleBundleImport(_ result: Result<URL, Error>) {
        importMessages = []
        guard case .success(let url) = result else {
            importMessages = ["Error: could not access folder."]
            return
        }
        guard url.startAccessingSecurityScopedResource() else {
            importMessages = ["Error: permission denied."]
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let manifest = try MigrationService.readManifest(from: url)
            importMessages.append("Bundle from app version \(manifest.sourceAppVersion ?? "unknown").")

            let entries = try MigrationService.readBundleSites(from: url, manifest: manifest)
            let existingDomains = Set(store.sites.map(\.domain))
            let validationErrors = MigrationService.validateEntries(entries, existingDomains: existingDomains)

            if !validationErrors.isEmpty {
                for error in validationErrors {
                    importMessages.append("Validation: \(error.localizedDescription)")
                }
            }

            // Import valid entries via the store
            let sitesData = try JSONEncoder().encode(entries)
            let (imported, errors) = try store.importLegacySites(from: sitesData)
            importMessages.append("Imported \(imported.count) site(s).")
            for error in errors {
                importMessages.append("Skipped: \(error.localizedDescription)")
            }

            let dumps = MigrationService.listDatabaseDumps(in: url)
            if !dumps.isEmpty {
                importMessages.append("\(dumps.count) database dump(s) found. Restore them manually with the MariaDB client.")
            }
        } catch {
            importMessages.append("Error: \(error.localizedDescription)")
        }
    }
}
