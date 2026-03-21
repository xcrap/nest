import SwiftUI
import UniformTypeIdentifiers

public struct SitesView: View {
    @EnvironmentObject var store: SiteStore
    @EnvironmentObject var processController: ProcessController
    @State private var showAddSheet = false
    @State private var editingSite: Site?
    @State private var showImportPicker = false
    @State private var importResult: ImportResult?
    @State private var showExportPicker = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Sites")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                servicesControls
                Menu {
                    Button("Import Sites…") { showImportPicker = true }
                    Button("Export Sites…") { showExportPicker = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            .padding()

            Divider()

            if store.sites.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "globe")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No Sites")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Add a site to get started, or import from a legacy export.")
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 12) {
                        Button("Add Site") { showAddSheet = true }
                        Button("Import…") { showImportPicker = true }
                    }
                }
                .padding()
                Spacer()
            } else {
                List {
                    ForEach(store.sites) { site in
                        SiteRow(site: site, onEdit: { editingSite = site })
                    }
                    .onDelete(perform: deleteSites)
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            SiteFormSheet(mode: .add)
        }
        .sheet(item: $editingSite) { site in
            SiteFormSheet(mode: .edit(site))
        }
        .fileImporter(isPresented: $showImportPicker, allowedContentTypes: [.json]) { result in
            handleImport(result)
        }
        .fileExporter(isPresented: $showExportPicker, document: SiteExportDocument(data: (try? store.exportSites()) ?? Data()), contentType: .json, defaultFilename: "nest-sites.json") { _ in }
        .alert("Import Result", isPresented: .init(get: { importResult != nil }, set: { if !$0 { importResult = nil } })) {
            Button("OK") { importResult = nil }
        } message: {
            if let result = importResult {
                Text(result.message)
            }
        }
    }

    private var servicesControls: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(processController.frankenphpRunning ? .green : .secondary.opacity(0.3))
                .frame(width: 8, height: 8)
            Text(processController.frankenphpRunning ? "Running" : "Stopped")
                .font(.caption)
                .foregroundStyle(.secondary)

            if processController.frankenphpRunning {
                Button("Stop") {
                    processController.stopFrankenPHP()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.red)
            } else {
                Button("Start") {
                    startServices()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.blue)
            }
        }
    }

    private func startServices() {
        let paths = store.settings.runtimePaths
        guard !paths.frankenphpBinary.isEmpty else { return }

        let renderer = ConfigRenderer(
            configDirectory: store.settings.configDirectory,
            logDirectory: paths.logDirectory
        )
        try? renderer.writeAll(sites: store.sites)
        processController.startFrankenPHP(binary: paths.frankenphpBinary, caddyfilePath: renderer.caddyfilePath)
    }

    private func deleteSites(at offsets: IndexSet) {
        for index in offsets {
            store.deleteSite(id: store.sites[index].id)
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let data = try? Data(contentsOf: url) else {
            importResult = ImportResult(message: "Could not read file.")
            return
        }

        do {
            let (imported, errors) = try store.importLegacySites(from: data)
            var msg = "Imported \(imported.count) site(s)."
            if !errors.isEmpty {
                msg += "\n\(errors.count) skipped:\n" + errors.map(\.localizedDescription).joined(separator: "\n")
            }
            importResult = ImportResult(message: msg)
        } catch {
            importResult = ImportResult(message: error.localizedDescription)
        }
    }
}

public struct ImportResult {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

// MARK: - Site Row

public struct SiteRow: View {
    @EnvironmentObject var store: SiteStore
    @EnvironmentObject var processController: ProcessController
    public let site: Site
    public let onEdit: () -> Void

    public init(site: Site, onEdit: @escaping () -> Void) {
        self.site = site
        self.onEdit = onEdit
    }

    public var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(site.status == .running ? .green : .secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                    Text(site.name)
                        .fontWeight(.medium)
                }
                Text(site.domain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(site.rootPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 8) {
                if site.status == .running {
                    Button("Stop") {
                        store.setSiteStatus(id: site.id, status: .stopped)
                        reloadConfig()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .font(.caption)
                } else {
                    Button("Start") {
                        store.setSiteStatus(id: site.id, status: .running)
                        reloadConfig()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.green)
                    .font(.caption)
                }

                Button {
                    onEdit()
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func reloadConfig() {
        let renderer = ConfigRenderer(
            configDirectory: store.settings.configDirectory,
            logDirectory: store.settings.runtimePaths.logDirectory
        )
        try? renderer.writeAll(sites: store.sites)
        if processController.frankenphpRunning {
            processController.reloadFrankenPHP(caddyfilePath: renderer.caddyfilePath)
        }
    }
}

// MARK: - Export Document

public struct SiteExportDocument: FileDocument {
    public static var readableContentTypes = [UTType.json]
    public let data: Data

    public init(data: Data) {
        self.data = data
    }

    public init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
