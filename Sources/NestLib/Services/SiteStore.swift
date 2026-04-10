import Foundation
import Combine

/// Persists sites and app settings as JSON in the app support directory.
@MainActor
public final class SiteStore: ObservableObject {
    @Published public var sites: [Site] = []
    @Published public var appProjects: [AppProject] = []
    @Published public var tunnelRoutes: [TunnelRoute] = []
    @Published public var settings: AppSettings

    private let sitesFileURL: URL
    private let projectsFileURL: URL
    private let tunnelRoutesFileURL: URL
    private let settingsFileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        let defaults = AppSettings.defaultSettings()
        AppSettings.prepareStorage()
        let nestDir = AppSettings.nestDataDirectory

        let fm = FileManager.default
        try? fm.createDirectory(atPath: nestDir, withIntermediateDirectories: true)

        self.sitesFileURL = URL(fileURLWithPath: nestDir).appendingPathComponent("sites.json")
        self.projectsFileURL = URL(fileURLWithPath: nestDir).appendingPathComponent("projects.json")
        self.tunnelRoutesFileURL = URL(fileURLWithPath: nestDir).appendingPathComponent("tunnels.json")
        self.settingsFileURL = URL(fileURLWithPath: nestDir).appendingPathComponent("settings.json")

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

        loadSettings()
        loadSites()
        loadProjects()
        loadTunnelRoutes()
        reconcileTunnelLinks()
        runOneTimeMindMigrationIfNeeded()
    }

    // MARK: - Persistence

    private func loadSites() {
        guard let data = try? Data(contentsOf: sitesFileURL) else { return }
        if let loaded = try? decoder.decode([Site].self, from: data) {
            sites = loaded
        }
    }

    private func saveSites() {
        guard let data = try? encoder.encode(sites) else { return }
        try? data.write(to: sitesFileURL, options: .atomic)
    }

    private func loadProjects() {
        guard let data = try? Data(contentsOf: projectsFileURL) else { return }
        if let loaded = try? decoder.decode([AppProject].self, from: data) {
            appProjects = loaded
        }
    }

    private func saveProjects() {
        guard let data = try? encoder.encode(appProjects) else { return }
        try? data.write(to: projectsFileURL, options: .atomic)
    }

    private func loadTunnelRoutes() {
        guard let data = try? Data(contentsOf: tunnelRoutesFileURL) else { return }
        if let loaded = try? decoder.decode([TunnelRoute].self, from: data) {
            tunnelRoutes = loaded
        }
    }

    private func saveTunnelRoutes() {
        guard let data = try? encoder.encode(tunnelRoutes) else { return }
        try? data.write(to: tunnelRoutesFileURL, options: .atomic)
    }

    private func loadSettings() {
        guard let data = try? Data(contentsOf: settingsFileURL) else { return }
        if let loaded = try? decoder.decode(AppSettings.self, from: data) {
            settings = loaded
            let normalizedRuntimePaths = settings.runtimePaths.fillingMissingValues()
            var migratedRuntimePaths = normalizedRuntimePaths
            let legacyCloudflaredLog = "/opt/homebrew/var/log/cloudflared.log"
            let preferredCloudflaredLog = RuntimePaths.detectDefaults().cloudflaredLog

            if migratedRuntimePaths.cloudflaredLog == legacyCloudflaredLog,
               !preferredCloudflaredLog.isEmpty {
                migratedRuntimePaths.cloudflaredLog = preferredCloudflaredLog
            }

            if migratedRuntimePaths != settings.runtimePaths {
                settings.runtimePaths = migratedRuntimePaths
                saveSettings()
            }
        }
    }

    public func saveSettings() {
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: settingsFileURL, options: .atomic)
    }

    // MARK: - Site CRUD

    public func addSite(name: String, domain: String, rootPath: String, documentRoot: String) -> Site {
        let site = Site(
            name: name,
            domain: domain.hasSuffix(".test") ? domain : "\(domain).test",
            rootPath: rootPath,
            documentRoot: documentRoot
        )
        sites.append(site)
        saveSites()
        return site
    }

    public func updateSite(_ site: Site) {
        guard let index = sites.firstIndex(where: { $0.id == site.id }) else { return }
        var updated = site
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
            name: name,
            hostname: hostname,
            directory: directory,
            port: port,
            command: command
        )
        appProjects.append(project)
        saveProjects()
        reconcileTunnelLinks()
        return project
    }

    public func updateProject(_ project: AppProject) {
        guard let index = appProjects.firstIndex(where: { $0.id == project.id }) else { return }
        var updated = project
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
        tunnelRoutes.append(route)
        saveTunnelRoutes()
        reconcileTunnelLinks()
    }

    public func updateTunnelRoute(_ route: TunnelRoute) {
        guard let index = tunnelRoutes.firstIndex(where: { $0.id == route.id }) else { return }
        var updated = route
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
        tunnelRoutes = routes
        saveTunnelRoutes()
        reconcileTunnelLinks()
    }

    public func replaceCloudflareSettings(_ cloudflareSettings: CloudflareSettings) {
        settings.cloudflareSettings = cloudflareSettings
        saveSettings()
    }

    public func exportCloudflareSettings() throws -> Data {
        try encoder.encode(settings.cloudflareSettings)
    }

    public func importCloudflareSettings(from data: Data) throws {
        let imported = try decoder.decode(CloudflareSettings.self, from: data)
        settings.cloudflareSettings = imported
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

        appProjects = updatedProjects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        tunnelRoutes = updatedRoutes.sorted { $0.publicHostname.localizedCaseInsensitiveCompare($1.publicHostname) == .orderedAscending }

        settings.cloudflareSettings = payload.cloudflareSettings
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

            let domain = entry.domain.hasSuffix(".test") ? entry.domain : "\(entry.domain).test"

            if existingDomains.contains(domain) || imported.contains(where: { $0.domain == domain }) {
                errors.append(.duplicateDomain(domain: domain))
                continue
            }

            let docRoot = Site.inferDocumentRoot(rootPath: entry.rootPath, specified: entry.documentRoot)

            let site = Site(
                name: name,
                domain: domain,
                rootPath: entry.rootPath,
                documentRoot: docRoot
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
