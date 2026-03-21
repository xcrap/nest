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
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

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
                                .onHover { h in
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        hoveredSiteId = h ? site.id : nil
                                    }
                                }
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

// MARK: - Compact Site Row (single line, stable height)

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

    private var isRunning: Bool { site.status == .running }

    public var body: some View {
        HStack(spacing: 10) {
            // Status
            Circle()
                .fill(isRunning ? Color.green : Color.secondary.opacity(0.2))
                .frame(width: 8, height: 8)

            // Name
            Text(site.name)
                .font(.callout)
                .fontWeight(.medium)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)

            // Domain
            Text(site.domain)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)

            // Path
            Text(site.rootPath)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Hover actions — always rendered, opacity-controlled
            HStack(spacing: 0) {
                rowAction(icon: "pencil", help: "Edit") { onEdit() }
                rowAction(icon: "trash", help: "Delete") {
                    store.deleteSite(id: site.id)
                    reloadConfig()
                }
            }
            .opacity(isHovered ? 1 : 0)

            // Start/Stop
            StartStopButton(isRunning: isRunning) {
                let newStatus: SiteStatus = isRunning ? .stopped : .running
                store.setSiteStatus(id: site.id, status: newStatus)
                reloadConfig()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isHovered ? Color.primary.opacity(0.03) : Color.clear)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Edit...") { onEdit() }
            Button(isRunning ? "Stop" : "Start") {
                store.setSiteStatus(id: site.id, status: isRunning ? .stopped : .running)
                reloadConfig()
            }
            Divider()
            Button("Delete", role: .destructive) {
                store.deleteSite(id: site.id)
                reloadConfig()
            }
        }
    }

    @State private var hoveredAction: String?

    private func rowAction(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.callout)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hoveredAction == icon ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hoveredAction == icon ? .primary : .secondary)
        .onHover { h in hoveredAction = h ? icon : nil }
        .help(help)
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

// MARK: - Start/Stop Button with hover

struct StartStopButton: View {
    let isRunning: Bool
    let action: () -> Void
    @State private var isButtonHovered = false

    var body: some View {
        Button(action: action) {
            Text(isRunning ? "Stop" : "Start")
                .font(.caption)
                .fontWeight(.medium)
                .frame(width: 36)
                .padding(.vertical, 3)
                .padding(.horizontal, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(buttonFill)
                )
                .foregroundStyle(isRunning ? Color.red : Color.green)
        }
        .buttonStyle(.plain)
        .onHover { h in isButtonHovered = h }
    }

    private var buttonFill: Color {
        if isButtonHovered {
            return isRunning ? Color.red.opacity(0.18) : Color.green.opacity(0.18)
        }
        return isRunning ? Color.red.opacity(0.08) : Color.green.opacity(0.08)
    }
}
