import Foundation
import Combine

/// Persists sites and app settings as JSON in the app support directory.
@MainActor
public final class SiteStore: ObservableObject {
    @Published public var sites: [Site] = []
    @Published public var appProjects: [AppProject] = []
    @Published public var tunnelRoutes: [TunnelRoute] = []
    @Published public var settings: AppSettings
    @Published public private(set) var persistenceErrors: [String] = []

    private let sitesFileURL: URL
    private let projectsFileURL: URL
    private let tunnelRoutesFileURL: URL
    private let settingsFileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private enum StoreSource {
        case envelope
        case legacy
    }

    private struct LoadedValue<T> {
        var value: T
        var source: StoreSource
    }

    public convenience init() {
        let defaults = AppSettings.defaultSettings()
        AppSettings.prepareStorage()
        self.init(
            dataDirectory: URL(fileURLWithPath: AppSettings.nestDataDirectory),
            defaults: defaults,
            runOneTimeMigrations: true
        )
    }

    public init(
        dataDirectory: URL,
        defaults: AppSettings = AppSettings.defaultSettings(),
        runOneTimeMigrations: Bool = true
    ) {
        var initialPersistenceErrors: [String] = []
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        } catch {
            initialPersistenceErrors.append("Cannot create Nest data directory: \(error.localizedDescription)")
        }

        self.sitesFileURL = dataDirectory.appendingPathComponent("sites.json")
        self.projectsFileURL = dataDirectory.appendingPathComponent("projects.json")
        self.tunnelRoutesFileURL = dataDirectory.appendingPathComponent("tunnels.json")
        self.settingsFileURL = dataDirectory.appendingPathComponent("settings.json")

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)

            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractionalFormatter.date(from: dateString) { return date }

            let plainFormatter = ISO8601DateFormatter()
            plainFormatter.formatOptions = [.withInternetDateTime]
            if let date = plainFormatter.date(from: dateString) { return date }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date: \(dateString)")
        }
        self.decoder = dec

        self.settings = defaults
        self.persistenceErrors = initialPersistenceErrors

        loadSettings()
        loadSites()
        loadProjects()
        loadTunnelRoutes()
        reconcileTunnelLinks()
        if runOneTimeMigrations {
            runOneTimeMindMigrationIfNeeded()
        }
    }

    // MARK: - Persistence

    private func loadSites() {
        if let result: LoadedValue<[Site]> = loadStoredValue([Site].self, from: sitesFileURL, label: "sites") {
            let loaded = result.value
            sites = loaded
            if result.source == .legacy {
                saveSites()
            }
        }
    }

    private func saveSites() {
        saveEncodable(sites, to: sitesFileURL, label: "sites")
    }

    private func loadProjects() {
        if let result: LoadedValue<[AppProject]> = loadStoredValue([AppProject].self, from: projectsFileURL, label: "projects") {
            let loaded = result.value
            appProjects = loaded
            if result.source == .legacy {
                saveProjects()
            }
        }
    }

    private func saveProjects() {
        saveEncodable(appProjects, to: projectsFileURL, label: "projects")
    }

    private func loadTunnelRoutes() {
        if let result: LoadedValue<[TunnelRoute]> = loadStoredValue([TunnelRoute].self, from: tunnelRoutesFileURL, label: "tunnel routes") {
            let loaded = result.value
            tunnelRoutes = loaded
            if result.source == .legacy {
                saveTunnelRoutes()
            }
        }
    }

    private func saveTunnelRoutes() {
        saveEncodable(tunnelRoutes, to: tunnelRoutesFileURL, label: "tunnel routes")
    }

    private func loadSettings() {
        if let result: LoadedValue<AppSettings> = loadStoredValue(AppSettings.self, from: settingsFileURL, label: "settings") {
            let loaded = result.value
            settings = loaded
            let normalizedRuntimePaths = settings.runtimePaths.fillingMissingValues()
            var migratedRuntimePaths = normalizedRuntimePaths
            let legacyCloudflaredLog = "/opt/homebrew/var/log/cloudflared.log"
            let preferredCloudflaredLog = RuntimePaths.detectDefaults().cloudflaredLog

            if migratedRuntimePaths.cloudflaredLog == legacyCloudflaredLog,
               !preferredCloudflaredLog.isEmpty {
                migratedRuntimePaths.cloudflaredLog = preferredCloudflaredLog
            }

            if migratedRuntimePaths != settings.runtimePaths || result.source == .legacy {
                settings.runtimePaths = migratedRuntimePaths
                saveSettings()
            }
        }
    }

    public func saveSettings() {
        saveEncodable(settings, to: settingsFileURL, label: "settings")
    }

    private func loadStoredValue<T: Codable>(_ type: T.Type, from url: URL, label: String) -> LoadedValue<T>? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            recordPersistenceError("Cannot read \(label): \(error.localizedDescription)")
            return nil
        }

        do {
            let envelope = try decoder.decode(StoreEnvelope<T>.self, from: data)
            guard envelope.schemaVersion <= StoreSchema.currentVersion else {
                let backupMessage = backupInvalidFile(url)
                recordPersistenceError("Cannot decode \(label): schema version \(envelope.schemaVersion) is newer than supported version \(StoreSchema.currentVersion). \(backupMessage)")
                return nil
            }
            return LoadedValue(value: envelope.payload, source: .envelope)
        } catch let envelopeError {
            do {
                let legacy = try decoder.decode(type, from: data)
                let backupMessage = backupLegacyFile(url)
                recordPersistenceError("Migrated legacy \(label) storage to schema version \(StoreSchema.currentVersion). \(backupMessage)")
                return LoadedValue(value: legacy, source: .legacy)
            } catch {
                let backupMessage = backupInvalidFile(url)
                recordPersistenceError("Cannot decode \(label): \(envelopeError.localizedDescription). \(backupMessage)")
                return nil
            }
        }
    }

    private func saveEncodable<T: Codable>(_ value: T, to url: URL, label: String) {
        do {
            let envelope = StoreEnvelope(payload: value)
            let data = try encoder.encode(envelope)
            try data.write(to: url, options: .atomic)
        } catch {
            recordPersistenceError("Cannot save \(label): \(error.localizedDescription)")
        }
    }

    private func backupLegacyFile(_ url: URL) -> String {
        backupFile(url, suffix: "legacy")
    }

    private func backupInvalidFile(_ url: URL) -> String {
        backupFile(url, suffix: "invalid")
    }

    private func backupFile(_ url: URL, suffix: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).\(suffix)-\(timestamp)")

        do {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.copyItem(at: url, to: backupURL)
            return "A backup was written to \(backupURL.path)."
        } catch {
            return "Could not back up the \(suffix) file: \(error.localizedDescription)."
        }
    }

    private func recordPersistenceError(_ message: String) {
        guard !persistenceErrors.contains(message) else { return }
        persistenceErrors.append(message)
    }

    private func normalizedSite(_ site: Site) -> Site {
        var updated = site
        updated.name = NestValidation.normalizedName(site.name)
        updated.domain = NestValidation.normalizedDomain(site.domain, defaultTLD: "test")
        updated.rootPath = site.rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.documentRoot = NestValidation.normalizedRelativePath(site.documentRoot)
        return updated
    }

    private func normalizedProject(_ project: AppProject) -> AppProject {
        var updated = project
        updated.name = NestValidation.normalizedName(project.name)
        updated.hostname = NestValidation.normalizedDomain(project.hostname)
        updated.directory = project.directory.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.command = project.command.trimmingCharacters(in: .whitespacesAndNewlines)
        return updated
    }

    private func normalizedTunnelRoute(_ route: TunnelRoute) -> TunnelRoute {
        var updated = route
        updated.subdomain = route.subdomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        updated.publicDomain = NestValidation.normalizedDomain(route.publicDomain)
        updated.localDomain = NestValidation.normalizedDomain(route.localDomain)
        let linkedSiteDomain = route.linkedSiteDomain.map { NestValidation.normalizedDomain($0, defaultTLD: "test") }
        updated.linkedSiteDomain = linkedSiteDomain?.isEmpty == true ? nil : linkedSiteDomain
        return updated
    }

    // MARK: - Site CRUD

    public func addSite(name: String, domain: String, rootPath: String, documentRoot: String) -> Site {
        let site = Site(
            name: NestValidation.normalizedName(name),
            domain: NestValidation.normalizedDomain(domain, defaultTLD: "test"),
            rootPath: rootPath.trimmingCharacters(in: .whitespacesAndNewlines),
            documentRoot: NestValidation.normalizedRelativePath(documentRoot)
        )
        sites.append(site)
        saveSites()
        return site
    }

    public func updateSite(_ site: Site) {
        guard let index = sites.firstIndex(where: { $0.id == site.id }) else { return }
        var updated = normalizedSite(site)
        updated.updatedAt = Date()
        sites[index] = updated
        saveSites()
        reconcileTunnelLinks()
    }

    public func deleteSite(id: String) {
        sites.removeAll { $0.id == id }
        saveSites()
        reconcileTunnelLinks()
    }

    public func setSiteStatus(id: String, status: SiteStatus) {
        guard let index = sites.firstIndex(where: { $0.id == id }) else { return }
        sites[index].status = status
        sites[index].updatedAt = Date()
        saveSites()
    }

    public func site(forDomain domain: String) -> Site? {
        sites.first { $0.domain == domain }
    }

    public var runningSites: [Site] {
        sites.filter { $0.status == .running }
    }

    // MARK: - Project CRUD

    public func addProject(name: String, hostname: String, directory: String, port: Int, command: String) -> AppProject {
        let project = AppProject(
            id: AppProject.defaultID(from: name).isEmpty ? UUID().uuidString : AppProject.defaultID(from: name),
            name: NestValidation.normalizedName(name),
            hostname: NestValidation.normalizedDomain(hostname),
            directory: directory.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            command: command.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        appProjects.append(project)
        saveProjects()
        reconcileTunnelLinks()
        return project
    }

    public func updateProject(_ project: AppProject) {
        guard let index = appProjects.firstIndex(where: { $0.id == project.id }) else { return }
        var updated = normalizedProject(project)
        updated.updatedAt = Date()
        appProjects[index] = updated
        saveProjects()
        reconcileTunnelLinks()
    }

    public func deleteProject(id: String) {
        appProjects.removeAll { $0.id == id }
        saveProjects()
        reconcileTunnelLinks()
    }

    public func project(forHostname hostname: String) -> AppProject? {
        appProjects.first { $0.hostname == hostname }
    }

    public func project(id: String?) -> AppProject? {
        guard let id else { return nil }
        return appProjects.first { $0.id == id }
    }

    // MARK: - Tunnel CRUD

    public func addTunnelRoute(_ route: TunnelRoute) {
        tunnelRoutes.append(normalizedTunnelRoute(route))
        saveTunnelRoutes()
        reconcileTunnelLinks()
    }

    public func updateTunnelRoute(_ route: TunnelRoute) {
        guard let index = tunnelRoutes.firstIndex(where: { $0.id == route.id }) else { return }
        var updated = normalizedTunnelRoute(route)
        updated.updatedAt = Date()
        tunnelRoutes[index] = updated
        saveTunnelRoutes()
        reconcileTunnelLinks()
    }

    public func deleteTunnelRoute(id: String) {
        tunnelRoutes.removeAll { $0.id == id }
        saveTunnelRoutes()
    }

    public func tunnelRoute(forHostname hostname: String) -> TunnelRoute? {
        tunnelRoutes.first { $0.publicHostname == hostname }
    }

    public func replaceTunnelRoutes(_ routes: [TunnelRoute]) {
        tunnelRoutes = routes.map(normalizedTunnelRoute)
        saveTunnelRoutes()
        reconcileTunnelLinks()
    }

    public func replaceCloudflareSettings(_ cloudflareSettings: CloudflareSettings) {
        settings.cloudflareSettings = NestValidation.normalizedCloudflareSettings(cloudflareSettings)
        saveSettings()
    }

    public func exportCloudflareSettings() throws -> Data {
        try encoder.encode(settings.cloudflareSettings)
    }

    public func importCloudflareSettings(from data: Data) throws {
        let imported = try decoder.decode(CloudflareSettings.self, from: data)
        settings.cloudflareSettings = NestValidation.normalizedCloudflareSettings(imported)
        saveSettings()
    }

    public func applyMindImport(_ payload: MindImportPayload) -> MindImportSummary {
        var importedProjects = 0
        var importedRoutes = 0
        var updatedProjects = appProjects
        var updatedRoutes = tunnelRoutes

        for project in payload.projects {
            if let index = updatedProjects.firstIndex(where: { $0.hostname == project.hostname || $0.id == project.id }) {
                var replacement = project
                replacement.id = updatedProjects[index].id
                replacement.createdAt = updatedProjects[index].createdAt
                updatedProjects[index] = replacement
            } else {
                updatedProjects.append(project)
                importedProjects += 1
            }
        }

        for route in payload.tunnelRoutes {
            if let index = updatedRoutes.firstIndex(where: { $0.publicHostname == route.publicHostname }) {
                var replacement = route
                replacement.id = updatedRoutes[index].id
                replacement.createdAt = updatedRoutes[index].createdAt
                updatedRoutes[index] = replacement
            } else {
                updatedRoutes.append(route)
                importedRoutes += 1
            }
        }

        appProjects = updatedProjects
            .map(normalizedProject)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        tunnelRoutes = updatedRoutes
            .map(normalizedTunnelRoute)
            .sorted { $0.publicHostname.localizedCaseInsensitiveCompare($1.publicHostname) == .orderedAscending }

        settings.cloudflareSettings = NestValidation.normalizedCloudflareSettings(payload.cloudflareSettings)
        settings.mindProjectDirectory = payload.sourceDirectory.path
        settings.hasCompletedMindMigration = true

        saveProjects()
        saveTunnelRoutes()
        saveSettings()
        reconcileTunnelLinks()

        return MindImportSummary(
            importedProjects: importedProjects,
            importedRoutes: importedRoutes,
            warnings: payload.warnings
        )
    }

    // MARK: - Import / Export

    /// Import sites from legacy export format. Returns the list of imported sites and any validation errors.
    public func importLegacySites(from data: Data) throws -> (imported: [Site], errors: [ImportValidationError]) {
        var entries: [LegacySiteEntry] = []

        // Try v1 format first
        if let export = try? decoder.decode(LegacySiteExport.self, from: data) {
            entries = export.sites
        } else if let array = try? decoder.decode([LegacySiteEntry].self, from: data) {
            entries = array
        } else {
            throw NSError(domain: "Nest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid import file format."])
        }

        var errors: [ImportValidationError] = []
        var imported: [Site] = []
        let existingDomains = Set(sites.map(\.domain))

        for entry in entries {
            let name = entry.name
            if entry.domain.isEmpty {
                errors.append(.missingDomain(siteName: name))
                continue
            }
            if entry.rootPath.isEmpty {
                errors.append(.missingRootPath(siteName: name))
                continue
            }

            let domain = NestValidation.normalizedDomain(entry.domain, defaultTLD: "test")

            if existingDomains.contains(domain) || imported.contains(where: { $0.domain == domain }) {
                errors.append(.duplicateDomain(domain: domain))
                continue
            }

            let docRoot = Site.inferDocumentRoot(rootPath: entry.rootPath, specified: entry.documentRoot)

            let site = Site(
                name: NestValidation.normalizedName(name),
                domain: domain,
                rootPath: entry.rootPath.trimmingCharacters(in: .whitespacesAndNewlines),
                documentRoot: NestValidation.normalizedRelativePath(docRoot)
            )
            imported.append(site)
        }

        sites.append(contentsOf: imported)
        saveSites()
        reconcileTunnelLinks()

        return (imported, errors)
    }

    public func exportSites() throws -> Data {
        let export = LegacySiteExport(
            version: 1,
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            sites: sites.map { site in
                LegacySiteEntry(
                    name: site.name,
                    domain: site.domain,
                    rootPath: site.rootPath,
                    documentRoot: site.documentRoot
                )
            }
        )
        return try encoder.encode(export)
    }

    public func importParkedFolderSites(from directory: URL) -> ParkedFolderImportSummary {
        let scan = ParkedFolderScanner.scan(
            directory: directory,
            existingDomains: Set(sites.map(\.domain))
        )
        var imported: [Site] = []

        for candidate in scan.candidates {
            let site = Site(
                name: candidate.name,
                domain: candidate.domain,
                rootPath: candidate.rootPath,
                documentRoot: candidate.documentRoot
            )
            sites.append(site)
            imported.append(site)
        }

        if !imported.isEmpty {
            saveSites()
            reconcileTunnelLinks()
        }

        return ParkedFolderImportSummary(
            imported: imported,
            skippedExistingDomains: scan.skippedExisting,
            skippedInvalidFolders: scan.skippedInvalid
        )
    }

    // MARK: - Linking

    public func reconcileTunnelLinks() {
        var updated = tunnelRoutes
        var changed = false

        for index in updated.indices {
            var route = updated[index]

            if route.kind == .php {
                let matchedSite = sites.first(where: {
                    $0.domain == route.localDomain
                    || $0.domain == route.linkedSiteDomain
                    || $0.domain == "\(route.localDomain).test"
                })

                let linkedDomain = matchedSite?.domain
                if route.linkedSiteDomain != linkedDomain {
                    route.linkedSiteDomain = linkedDomain
                    changed = true
                }
            } else {
                let matchedProject = appProjects.first(where: {
                    $0.id == route.linkedProjectID
                    || $0.hostname == route.localDomain
                    || $0.hostname == route.publicHostname
                    || $0.port == route.originPort
                })

                let linkedProjectID = matchedProject?.id
                if route.linkedProjectID != linkedProjectID {
                    route.linkedProjectID = linkedProjectID
                    changed = true
                }
            }

            updated[index] = route
        }

        if changed {
            tunnelRoutes = updated
            saveTunnelRoutes()
        }
    }

    private func runOneTimeMindMigrationIfNeeded() {
        guard !settings.hasCompletedMindMigration else { return }

        let directory = URL(fileURLWithPath: settings.mindProjectDirectory)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }

        guard let payload = try? MindImportService.buildPayload(
            from: directory,
            existingSites: sites,
            currentSettings: settings
        ) else {
            return
        }

        let hasImportableState =
            !payload.projects.isEmpty
            || !payload.tunnelRoutes.isEmpty
            || payload.cloudflareSettings.hasAPIConfiguration
            || payload.cloudflareSettings.hasLocalConfiguration

        guard hasImportableState else { return }

        _ = applyMindImport(payload)
    }
}
