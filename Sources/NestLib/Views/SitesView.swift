import SwiftUI
import UniformTypeIdentifiers

public struct SitesView: View {
    @EnvironmentObject var store: SiteStore
    @EnvironmentObject var processController: ProcessController
    @State private var showAddSheet = false
    @State private var editingSite: Site?
    @State private var searchText = ""
    @State private var showImportPicker = false
    @State private var showFolderImportPicker = false
    @State private var showExportPicker = false
    @State private var importResult: ImportResult?
    @State private var hoveredSiteId: String?

    public init() {}

    @State private var selection: String?
    @State private var sortOrder = [KeyPathComparator(\Site.name)]
    @State private var filter = "All"
    @State private var pendingDeletion: Site?
    @AppStorage("pinnedSites") private var pinnedSites = ""
    @AppStorage("recentSites") private var recentSites = ""

    private var pinned: Set<String> { Set(pinnedSites.split(separator: ",").map(String.init)) }
    private var recent: [String] { recentSites.split(separator: ",").map(String.init) }
    private var selectedSite: Site? { store.sites.first { $0.id == selection } }
    private var filteredSites: [Site] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var sites = store.sites.filter { site in
            (query.isEmpty || [site.name, site.domain, site.rootPath].contains { $0.localizedCaseInsensitiveContains(query) })
            && (filter != "Pinned" || pinned.contains(site.id))
            && (filter != "Recent" || recent.contains(site.id))
        }.sorted(using: sortOrder)
        if filter == "Recent" { sites.sort { (recent.firstIndex(of: $0.id) ?? Int.max) < (recent.firstIndex(of: $1.id) ?? Int.max) } }
        else { sites = sites.filter { pinned.contains($0.id) } + sites.filter { !pinned.contains($0.id) } }
        return sites
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Filter sites…", text: $searchText).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Filter sites by name, domain or path")
                Picker("Show", selection: $filter) {
                    Text("All").tag("All"); Text("Pinned").tag("Pinned"); Text("Recent").tag("Recent")
                }.frame(width: 115)
                Text("\(store.runningSites.count)/\(store.sites.count) enabled").font(.callout).foregroundStyle(.secondary)
                Menu("Import / Export") {
                    Button("Import Sites…") { showImportPicker = true }
                    Button("Import Parked Folder…") { showFolderImportPicker = true }
                    Button("Export Sites…") { showExportPicker = true }
                }.fixedSize()
                Button { showAddSheet = true } label: { Label("Add Site", systemImage: "plus") }
                    .labelStyle(.iconOnly).keyboardShortcut("n", modifiers: .command)
            }.padding(12).background(.bar)
            HStack {
                Text(processController.caddyApplyState.label).font(.callout).textSelection(.enabled)
                Spacer()
                Button("Apply") { processController.applyCaddy(settings: store.settings, sites: store.sites) }
                    .disabled(processController.caddyApplyState.isBusy || store.lastSaveError != nil)
            }.padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            if store.sites.isEmpty {
                ContentUnavailableView {
                    Label("No sites yet", systemImage: "globe")
                } actions: { Button("Add Site") { showAddSheet = true } }
            } else if filteredSites.isEmpty {
                ContentUnavailableView.search(text: searchText.isEmpty ? filter : searchText)
            } else {
                Table(filteredSites, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Pin") { site in
                        Button { togglePin(site) } label: {
                            Image(systemName: pinned.contains(site.id) ? "pin.fill" : "pin")
                        }.buttonStyle(.plain).accessibilityLabel("\(pinned.contains(site.id) ? "Unpin" : "Pin") \(site.name)")
                    }.width(28)
                    TableColumn("Name", value: \.name).width(min: 100, ideal: 150)
                    TableColumn("Domain", value: \.domain) { site in
                        Text(site.domain).font(.system(.callout, design: .monospaced))
                    }.width(min: 110, ideal: 170)
                    TableColumn("Folder", value: \.rootPath) { site in
                        Text(site.rootPath).foregroundStyle(.secondary).truncationMode(.middle).help(site.rootPath)
                    }.width(min: 100, ideal: 230)
                    TableColumn("Open") { site in
                        HStack(spacing: 10) {
                            Button { openSite(site) } label: { Image(systemName: "globe") }
                                .help("Open in Browser").accessibilityLabel("Open \(site.name) in browser")
                            Button { SiteActions.reveal(site) } label: { Image(systemName: "folder") }
                                .help("Show in Finder").accessibilityLabel("Show \(site.name) in Finder")
                            Button { SiteActions.terminal(site) } label: { Image(systemName: "terminal") }
                                .help("Open Terminal").accessibilityLabel("Open Terminal at \(site.name)")
                            Button { editingSite = site } label: { Image(systemName: "pencil") }
                                .help("Edit Site").accessibilityLabel("Edit \(site.name)")
                        }.buttonStyle(.borderless)
                    }.width(105)
                    TableColumn("Enabled") { site in
                        Toggle("Enable \(site.name)", isOn: Binding(
                            get: { site.status == .running },
                            set: { store.setSiteStatus(id: site.id, status: $0 ? .running : .stopped) }
                        )).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                            .disabled(processController.caddyApplyState.isBusy || processController.isServiceBusy("FrankenPHP"))
                    }.width(58)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let site = store.sites.first(where: { ids.contains($0.id) }) {
                        Button("Open in Browser") { openSite(site) }
                        Button("Show in Finder") { SiteActions.reveal(site) }
                        Button("Open Terminal") { SiteActions.terminal(site) }
                        Button("Edit…") { editingSite = site }
                        Button(pinned.contains(site.id) ? "Unpin" : "Pin") { togglePin(site) }
                        Divider()
                        Button("Delete Site…", role: .destructive) { pendingDeletion = site }
                    }
                } primaryAction: { ids in
                    if let site = store.sites.first(where: { ids.contains($0.id) }) { openSite(site) }
                }
            }
            if let site = selectedSite {
                HStack {
                    Text(site.domain).font(.callout)
                    Spacer()
                    Button("Open") { openSite(site) }.keyboardShortcut("o", modifiers: .command)
                    Button("Finder") { SiteActions.reveal(site) }.keyboardShortcut("f", modifiers: [.command, .shift])
                    Button("Terminal") { SiteActions.terminal(site) }.keyboardShortcut("t", modifiers: [.command, .shift])
                    Button("Edit") { editingSite = site }.keyboardShortcut("e", modifiers: .command)
                    Button("Delete…", role: .destructive) { pendingDeletion = site }
                }.padding(10).background(.bar).id(site.id)
            }
        }
        .sheet(isPresented: $showAddSheet) { SiteFormSheet(mode: .add) }
        .sheet(item: $editingSite) { SiteFormSheet(mode: .edit($0)) }
        .fileImporter(isPresented: $showImportPicker, allowedContentTypes: [.json], onCompletion: handleImport)
        .fileImporter(isPresented: $showFolderImportPicker, allowedContentTypes: [.folder], onCompletion: handleParkedFolderImport)
        .fileExporter(isPresented: $showExportPicker, document: SiteExportDocument(data: (try? store.exportSites()) ?? Data()), contentType: .json, defaultFilename: "nest-sites.json") { result in
            if case .failure(let error) = result { importResult = ImportResult(message: error.localizedDescription) }
        }
        .alert("Import / Export", isPresented: .init(get: { importResult != nil }, set: { if !$0 { importResult = nil } })) {
            Button("OK") { importResult = nil }
        } message: { Text(importResult?.message ?? "") }
        .alert("Delete Site?", isPresented: .init(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("Delete", role: .destructive) {
                if let site = pendingDeletion { store.deleteSite(id: site.id) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { Text("Remove \(pendingDeletion?.name ?? "this site") from Nest? Its files will stay on disk.") }
    }
    private func togglePin(_ site: Site) {
        var ids = pinned
        if ids.contains(site.id) { ids.remove(site.id) } else { ids.insert(site.id) }
        pinnedSites = ids.sorted().joined(separator: ",")
    }
    private func openSite(_ site: Site) {
        recentSites = ([site.id] + recent.filter { $0 != site.id }).prefix(20).joined(separator: ",")
        SiteActions.open(site)
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

    private func handleParkedFolderImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        let summary = store.importParkedFolderSites(from: url)
        var message = "Imported \(summary.imported.count) site(s)."
        if !summary.skippedExistingDomains.isEmpty {
            message += "\nSkipped existing domains:\n" + summary.skippedExistingDomains.joined(separator: "\n")
        }
        if !summary.skippedInvalidFolders.isEmpty {
            message += "\nSkipped invalid folders:\n" + summary.skippedInvalidFolders.joined(separator: "\n")
        }
        importResult = ImportResult(message: message)
    }
}

public struct ImportResult {
    public let message: String
    public init(message: String) { self.message = message }
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
    var isPending: Bool = false
    let action: () -> Void
    @State private var isButtonHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if isPending {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.secondary)
                        .frame(width: 36)
                } else {
                    Text(isRunning ? "Stop" : "Start")
                        .font(.caption)
                        .fontWeight(.medium)
                        .frame(width: 36)
                        .foregroundStyle(isRunning ? Color.red : Color.green)
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 2)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(buttonFill)
            )
        }
        .buttonStyle(.plain)
        .disabled(isPending)
        .onHover { h in isButtonHovered = h }
    }

    private var buttonFill: Color {
        if isPending {
            return isButtonHovered ? Color.primary.opacity(0.12) : Color.primary.opacity(0.06)
        }
        if isButtonHovered {
            return isRunning ? Color.red.opacity(0.18) : Color.green.opacity(0.18)
        }
        return isRunning ? Color.red.opacity(0.08) : Color.green.opacity(0.08)
    }
}
