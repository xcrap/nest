import SwiftUI
import UniformTypeIdentifiers

public struct SitesView: View {
    @EnvironmentObject var store: SiteStore
    @EnvironmentObject var processController: ProcessController
    @State private var showAddSheet = false
    @State private var editingSite: Site?
    @State private var searchText = ""
    @State private var showImportPicker = false
    @State private var showExportPicker = false
    @State private var importResult: ImportResult?
    @State private var hoveredSiteId: String?

    public init() {}

    private var filteredSites: [Site] {
        if searchText.isEmpty { return store.sites }
        let q = searchText.lowercased()
        return store.sites.filter {
            $0.name.lowercased().contains(q) || $0.domain.lowercased().contains(q)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            header
            Divider()

            if store.sites.isEmpty {
                emptyState
            } else {
                // Search
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                    TextField("Filter sites...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.callout)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.bar)

                Divider()

                // Sites list
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredSites) { site in
                            SiteRow(site: site, isHovered: hoveredSiteId == site.id, onEdit: { editingSite = site })
                                .onHover { hovering in
                                    hoveredSiteId = hovering ? site.id : nil
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Divider()

                // Footer
                HStack(spacing: 4) {
                    Text("\(store.sites.count) site\(store.sites.count == 1 ? "" : "s")")
                    Text("  ·  ")
                    Text("\(store.runningSites.count) active")
                        .foregroundStyle(store.runningSites.isEmpty ? Color.secondary : Color.green)
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
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

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Sites")
                    .font(.title2)
                    .fontWeight(.bold)
            }

            Spacer()

            // FrankenPHP toggle
            serverToggle

            Divider()
                .frame(height: 20)

            Menu {
                Button("Import Sites...") { showImportPicker = true }
                Button("Export Sites...") { showExportPicker = true }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                showAddSheet = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
            .help("Add Site (Cmd+N)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var serverToggle: some View {
        Button {
            if processController.frankenphpRunning {
                processController.stopFrankenPHP()
            } else {
                startServices()
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(processController.frankenphpRunning ? Color.green : Color.secondary.opacity(0.25))
                    .frame(width: 7, height: 7)
                Text(processController.frankenphpRunning ? "Server Running" : "Server Stopped")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(processController.frankenphpRunning
                          ? Color.green.opacity(0.1)
                          : Color.secondary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.08))
                        .frame(width: 80, height: 80)
                    Image(systemName: "globe")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 4) {
                    Text("No sites yet")
                        .font(.title3)
                        .fontWeight(.medium)
                    Text("Add your first site to start developing locally.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Site", systemImage: "plus")
                        .font(.callout)
                        .fontWeight(.medium)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            Spacer()
        }
    }

    // MARK: - Actions

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
    public init(message: String) { self.message = message }
}

// MARK: - Site Row

public struct SiteRow: View {
    @EnvironmentObject var store: SiteStore
    @EnvironmentObject var processController: ProcessController
    public let site: Site
    public let isHovered: Bool
    public let onEdit: () -> Void

    public init(site: Site, isHovered: Bool = false, onEdit: @escaping () -> Void) {
        self.site = site
        self.isHovered = isHovered
        self.onEdit = onEdit
    }

    public var body: some View {
        HStack(spacing: 12) {
            // Status dot
            Circle()
                .fill(site.status == .running ? Color.green : Color.secondary.opacity(0.2))
                .frame(width: 8, height: 8)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(site.name)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(site.domain)
                        .font(.caption)
                        .foregroundStyle(.blue.opacity(0.8))
                    Text("·")
                        .foregroundStyle(.quaternary)
                    Text(site.rootPath)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            // Actions (visible on hover)
            if isHovered {
                HStack(spacing: 2) {
                    Button {
                        onEdit()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Edit")

                    Button {
                        store.deleteSite(id: site.id)
                        reloadConfig()
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Delete")
                }
            }

            // Toggle button
            Button {
                if site.status == .running {
                    store.setSiteStatus(id: site.id, status: .stopped)
                } else {
                    store.setSiteStatus(id: site.id, status: .running)
                }
                reloadConfig()
            } label: {
                Text(site.status == .running ? "Stop" : "Start")
                    .font(.caption)
                    .fontWeight(.medium)
                    .frame(width: 42)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(site.status == .running
                                  ? Color.red.opacity(0.1)
                                  : Color.green.opacity(0.1))
                    )
                    .foregroundStyle(site.status == .running ? .red : .green)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.04) : .clear)
        )
        .padding(.horizontal, 6)
        .contextMenu {
            Button("Edit...") { onEdit() }
            Button(site.status == .running ? "Stop" : "Start") {
                store.setSiteStatus(id: site.id, status: site.status == .running ? .stopped : .running)
                reloadConfig()
            }
            Divider()
            Button("Delete", role: .destructive) {
                store.deleteSite(id: site.id)
                reloadConfig()
            }
        }
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

    public init(data: Data) { self.data = data }

    public init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
