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
        let sorted = store.sites.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if searchText.isEmpty { return sorted }
        let q = searchText.lowercased()
        return sorted.filter {
            $0.name.lowercased().contains(q) || $0.domain.lowercased().contains(q)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Toolbar row
            HStack(spacing: 10) {
                // Search
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                        .font(.callout)
                    TextField("Filter...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.callout)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )

                Spacer()

                Text("\(store.runningSites.count)/\(store.sites.count) active")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Menu {
                    Button("Import Sites...") { showImportPicker = true }
                    Button("Export Sites...") { showExportPicker = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut("n", modifiers: .command)
                .help("Add Site (Cmd+N)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            if store.sites.isEmpty {
                emptyState
            } else {
                // Sites table
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredSites) { site in
                            SiteRow(site: site, isHovered: hoveredSiteId == site.id, onEdit: { editingSite = site })
                                .onHover { h in hoveredSiteId = h ? site.id : nil }
                            if site.id != filteredSites.last?.id {
                                Divider().padding(.leading, 32)
                            }
                        }
                    }
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

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: "globe")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.quaternary)
                Text("No sites yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Add Site") { showAddSheet = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Spacer()
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
    public init(message: String) { self.message = message }
}

// MARK: - Compact Site Row (single line)

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
        HStack(spacing: 8) {
            // Status
            Circle()
                .fill(site.status == .running ? Color.green : Color.secondary.opacity(0.2))
                .frame(width: 7, height: 7)

            // Name
            Text(site.name)
                .font(.callout)
                .fontWeight(.medium)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)

            // Domain
            Text(site.domain)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.blue.opacity(0.7))
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)

            // Path (truncated, fills remaining space)
            Text(site.rootPath)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Hover actions
            if isHovered {
                Button { onEdit() } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button {
                    store.deleteSite(id: site.id)
                    reloadConfig()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            // Start/Stop
            Button {
                let newStatus: SiteStatus = site.status == .running ? .stopped : .running
                store.setSiteStatus(id: site.id, status: newStatus)
                reloadConfig()
            } label: {
                Text(site.status == .running ? "Stop" : "Start")
                    .font(.caption)
                    .fontWeight(.medium)
                    .frame(width: 34)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(site.status == .running ? Color.red.opacity(0.1) : Color.green.opacity(0.1))
                    )
                    .foregroundStyle(site.status == .running ? Color.red : Color.green)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHovered ? Color.primary.opacity(0.03) : Color.clear)
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
            configDirectory: store.settings.caddyConfigDirectory,
            frankenphpLogPath: store.settings.runtimePaths.frankenphpLog
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
