import Foundation
import Combine

/// The JSON files Nest persists. Save failures are tracked per file so an error in one
/// never blocks, or gets cleared by, work on another.
public enum StoreFile: String, CaseIterable, Sendable {
    case sites, projects, tunnelRoutes, settings

    public var fileName: String {
        switch self {
        case .sites: return "sites.json"
        case .projects: return "projects.json"
        case .tunnelRoutes: return "tunnels.json"
        case .settings: return "settings.json"
        }
    }

    public var label: String {
        switch self {
        case .sites: return "sites"
        case .projects: return "projects"
        case .tunnelRoutes: return "tunnel routes"
        case .settings: return "settings"
        }
    }
}

/// Persists sites and app settings as JSON in the app support directory.
@MainActor
public final class SiteStore: ObservableObject {
    @Published public var sites: [Site] = []
    @Published public var appProjects: [AppProject] = []
    @Published public var tunnelRoutes: [TunnelRoute] = []
    @Published public var settings: AppSettings
    @Published public private(set) var persistenceErrors: [String] = []
    @Published public private(set) var saveErrors: [StoreFile: String] = [:]

    private let credentialStore: CredentialStore
    private var loadedToken: String?
    private var credentialLoaded = false
    /// Keychain read failures are reported here, not as a save error: nothing failed to save,
    /// and local work (sites, tunnels) does not need the token.
    @Published public private(set) var credentialError: String?
    /// Files that exist but could not be read at all. Nest never overwrites them.
    public private(set) var unreadableFiles: Set<StoreFile> = []
    private var settingsNeedSave = false

    private let dataDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// The first current save error, if any file failed to save.
    public var lastSaveError: String? {
        StoreFile.allCases.lazy.compactMap { self.saveErrors[$0] }.first
    }

    public func saveError(_ file: StoreFile) -> String? {
        saveErrors[file]
    }

    private enum StoreSource {
        case envelope
        case legacy
    }

    private struct LoadedValue<T> {
        var value: T
        var source: StoreSource
    }

    /// Decodes every readable element and counts the rest, so one bad record cannot empty a list.
    private struct LossyArray<Element: Decodable>: Decodable {
        var elements: [Element] = []
        var skipped = 0

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            while !container.isAtEnd {
                if let element = try? container.decode(Element.self) {
                    elements.append(element)
                } else {
                    _ = try container.decode(SkippedValue.self)
                    skipped += 1
                }
            }
        }
    }

    private struct SkippedValue: Decodable {
        init(from decoder: Decoder) throws {}
    }

    private struct LossyEnvelope<Element: Decodable>: Decodable {
        var schemaVersion: Int
        var payload: LossyArray<Element>
    }

    /// `loadsCredential: false` defers the Keychain read until `loadCredentialIfNeeded()`;
    /// nestctl uses it so commands that never need the token do not trigger Keychain prompts.
    public convenience init(loadsCredential: Bool = true) {
        if let directory = AppSettings.reviewDirectory {
            self.init(dataDirectory: URL(fileURLWithPath: directory), defaults: AppSettings(caddyConfigDirectory: directory + "/caddy"), runOneTimeMigrations: false, credentialStore: MemoryCredentialStore())
            return
        }
        AppSettings.prepareStorage()
        self.init(
            dataDirectory: URL(fileURLWithPath: AppSettings.nestDataDirectory),
            defaults: AppSettings.defaultSettings(),
            runOneTimeMigrations: loadsCredential,
            loadsCredential: loadsCredential
        )
    }

    /// `defaults` is only evaluated when no settings file exists, since detection launches FrankenPHP.
    public init(
        dataDirectory: URL,
        defaults: @autoclosure () -> AppSettings = AppSettings.defaultSettings(),
        runOneTimeMigrations: Bool = true,
        credentialStore: CredentialStore? = nil,
        loadsCredential: Bool = true
    ) {
        self.credentialStore = credentialStore ?? (runOneTimeMigrations || !loadsCredential ? KeychainCredentialStore() as CredentialStore : MemoryCredentialStore())
        var initialPersistenceErrors: [String] = []
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        } catch {
            initialPersistenceErrors.append("Cannot create Nest data directory: \(error.localizedDescription)")
        }

        self.dataDirectory = dataDirectory

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

        self.settings = AppSettings()
        self.persistenceErrors = initialPersistenceErrors

        if !loadSettings() {
            settings = defaults()
        }
        if loadsCredential {
            loadCredentialIfNeeded()
        }
        loadSites()
        loadProjects()
        loadTunnelRoutes()
        reconcileTunnelLinks()
        if runOneTimeMigrations {
            runOneTimeMindMigrationIfNeeded()
        }
    }

    /// Loads the Cloudflare token once, then saves any settings migration found at load.
    /// Settings are never written before this: saving would strip a legacy plaintext token
    /// before it reached the Keychain.
    public func loadCredentialIfNeeded() {
        guard !credentialLoaded else { return }
        credentialLoaded = true
        loadCredential()
        if settingsNeedSave, saveErrors[.settings] == nil, credentialError == nil {
            saveSettings()
        }
    }

    // MARK: - Persistence

    private func url(for file: StoreFile) -> URL {
        dataDirectory.appendingPathComponent(file.fileName)
    }

    private func loadSites() {
        guard let result = loadStoredArray(Site.self, file: .sites) else { return }
        let (unique, changed) = Self.deduplicatingIDs(result.value, id: \.id)
        sites = unique
        if result.source == .legacy || changed {
            saveSites()
        }
    }

    @discardableResult
    private func saveSites() -> Bool {
        saveEncodable(sites, file: .sites)
    }

    private func loadProjects() {
        guard let result = loadStoredArray(AppProject.self, file: .projects) else { return }
        let (unique, changed) = Self.deduplicatingIDs(result.value, id: \.id, key: AppProject.sanitizedID)
        appProjects = unique
        if changed {
            recordPersistenceError("Some projects shared an ID (and so a launch agent and log file); the duplicates were given new IDs.")
        }
        if result.source == .legacy || changed {
            saveProjects()
        }
    }

    @discardableResult
    private func saveProjects() -> Bool {
        saveEncodable(appProjects, file: .projects)
    }

    private func loadTunnelRoutes() {
        guard let result = loadStoredArray(TunnelRoute.self, file: .tunnelRoutes) else { return }
        let (unique, changed) = Self.deduplicatingIDs(result.value, id: \.id)
        tunnelRoutes = unique
        if result.source == .legacy || changed {
            saveTunnelRoutes()
        }
    }

    @discardableResult
    private func saveTunnelRoutes() -> Bool {
        saveEncodable(tunnelRoutes, file: .tunnelRoutes)
    }

    private static let legacyCloudflaredLog = "/opt/homebrew/var/log/cloudflared.log"

    /// Returns whether settings were loaded from disk. Migrations are saved once the token is known.
    private func loadSettings() -> Bool {
        guard let result = loadStoredObject(AppSettings.self, file: .settings) else { return false }
        settings = result.value
        var migratedRuntimePaths = settings.runtimePaths.fillingMissingValues()
        if migratedRuntimePaths.cloudflaredLog == Self.legacyCloudflaredLog {
            migratedRuntimePaths.cloudflaredLog = RuntimePaths.defaultCloudflaredLog
        }
        if migratedRuntimePaths != settings.runtimePaths {
            settings.runtimePaths = migratedRuntimePaths
            settingsNeedSave = true
        }
        if result.source == .legacy {
            settingsNeedSave = true
        }
        return true
    }

    @discardableResult
    public func saveSettings() -> Bool {
        do {
            if loadedToken == nil && settings.cloudflareSettings.apiToken.isEmpty {
                throw ConfigurationFailure("The Cloudflare token could not be loaded. Reopen Nest to retry Keychain access before saving settings.")
            }
            if loadedToken != settings.cloudflareSettings.apiToken {
                try credentialStore.save(settings.cloudflareSettings.apiToken)
                loadedToken = settings.cloudflareSettings.apiToken
            }
            let saved = saveEncodable(settings, file: .settings)
            if saved { settingsNeedSave = false }
            return saved
        } catch {
            saveErrors[.settings] = error.localizedDescription
            recordPersistenceError(error.localizedDescription)
            return false
        }
    }

    private func loadCredential() {
        let legacy = settings.cloudflareSettings.apiToken
        if !legacy.isEmpty {
            do {
                try credentialStore.save(legacy)
                loadedToken = legacy
                saveSettings() // Remove plaintext only after Keychain succeeds.
            } catch {
                // The plaintext token stays on disk, so settings must not be saved until this works.
                saveErrors[.settings] = error.localizedDescription
                recordPersistenceError(error.localizedDescription)
            }
        } else {
            do {
                let token = try credentialStore.load()
                settings.cloudflareSettings.apiToken = token
                loadedToken = token
            } catch {
                credentialError = error.localizedDescription
                recordPersistenceError(error.localizedDescription)
            }
        }
    }

    private func readStoredData(_ file: StoreFile) -> Data? {
        do {
            return try Data(contentsOf: url(for: file))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            markUnreadable(file, reason: "Cannot read \(file.label): \(error.localizedDescription).", backup: false)
            return nil
        }
    }

    /// A file written by Nest is always an envelope; never reinterpret one as a legacy payload.
    private func isEnvelope(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return object["schemaVersion"] != nil && object["payload"] != nil
    }

    private func isSupportedSchema(_ version: Int, file: StoreFile) -> Bool {
        guard version <= StoreSchema.currentVersion else {
            markUnreadable(file, reason: "Cannot decode \(file.label): schema version \(version) is newer than supported version \(StoreSchema.currentVersion).")
            return false
        }
        return true
    }

    private func loadStoredObject<T: Codable>(_ type: T.Type, file: StoreFile) -> LoadedValue<T>? {
        guard let data = readStoredData(file) else { return nil }
        do {
            let envelope = try decoder.decode(StoreEnvelope<T>.self, from: data)
            guard isSupportedSchema(envelope.schemaVersion, file: file) else { return nil }
            return LoadedValue(value: envelope.payload, source: .envelope)
        } catch let envelopeError {
            if !isEnvelope(data), let legacy = try? decoder.decode(type, from: data) {
                let backupMessage = backupFile(url(for: file), suffix: "legacy")
                recordPersistenceError("Migrated legacy \(file.label) storage to schema version \(StoreSchema.currentVersion). \(backupMessage)")
                return LoadedValue(value: legacy, source: .legacy)
            }
            markUnreadable(file, reason: "Cannot decode \(file.label): \(envelopeError.localizedDescription).")
            return nil
        }
    }

    private func loadStoredArray<Element: Codable>(_ type: Element.Type, file: StoreFile) -> LoadedValue<[Element]>? {
        guard let data = readStoredData(file) else { return nil }
        let envelopeError: Error
        do {
            let envelope = try decoder.decode(StoreEnvelope<[Element]>.self, from: data)
            guard isSupportedSchema(envelope.schemaVersion, file: file) else { return nil }
            return LoadedValue(value: envelope.payload, source: .envelope)
        } catch {
            envelopeError = error
        }

        if isEnvelope(data) {
            if let partial = try? decoder.decode(LossyEnvelope<Element>.self, from: data) {
                guard isSupportedSchema(partial.schemaVersion, file: file) else { return nil }
                reportSkippedRecords(partial.payload.skipped, file: file)
                return LoadedValue(value: partial.payload.elements, source: .envelope)
            }
        } else if let legacy = try? decoder.decode([Element].self, from: data) {
            let backupMessage = backupFile(url(for: file), suffix: "legacy")
            recordPersistenceError("Migrated legacy \(file.label) storage to schema version \(StoreSchema.currentVersion). \(backupMessage)")
            return LoadedValue(value: legacy, source: .legacy)
        } else if let partial = try? decoder.decode(LossyArray<Element>.self, from: data) {
            reportSkippedRecords(partial.skipped, file: file)
            return LoadedValue(value: partial.elements, source: .legacy)
        }

        markUnreadable(file, reason: "Cannot decode \(file.label): \(envelopeError.localizedDescription).")
        return nil
    }

    private func reportSkippedRecords(_ count: Int, file: StoreFile) {
        guard count > 0 else { return }
        let backupMessage = backupFile(url(for: file), suffix: "invalid")
        recordPersistenceError("\(count) \(file.label) record(s) could not be read and were skipped. \(backupMessage)")
    }

    private func markUnreadable(_ file: StoreFile, reason: String, backup: Bool = true) {
        unreadableFiles.insert(file)
        let backupMessage = backup ? " " + backupFile(url(for: file), suffix: "invalid") : ""
        recordPersistenceError("\(reason)\(backupMessage) Nest will not overwrite \(file.fileName) until it is repaired or removed.")
    }

    @discardableResult
    private func saveEncodable<T: Codable>(_ value: T, file: StoreFile) -> Bool {
        guard !unreadableFiles.contains(file) else {
            let message = "Cannot save \(file.label): \(file.fileName) could not be read when Nest started, so it was not overwritten. Repair or remove \(url(for: file).path) and reopen Nest."
            saveErrors[file] = message
            recordPersistenceError(message)
            return false
        }
        do {
            let envelope = StoreEnvelope(payload: value)
            let data = try encoder.encode(envelope)
            try data.write(to: url(for: file), options: .atomic)
            saveErrors[file] = nil
            return true
        } catch {
            let message = "Cannot save \(file.label): \(error.localizedDescription)"
            saveErrors[file] = message
            recordPersistenceError(message)
            return false
        }
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

    // MARK: - Identity

    /// Returns `base`, or `base-2`, `base-3`… whichever is not already taken (compared via `key`).
    static func uniqueID(base: String, taken: Set<String>, key: (String) -> String = { $0 }) -> String {
        if !taken.contains(key(base)) { return base }
        var suffix = 2
        while taken.contains(key("\(base)-\(suffix)")) { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    /// Later records that repeat an earlier ID get a fresh suffix; the first keeps its ID.
    static func deduplicatingIDs<T>(_ items: [T], id: WritableKeyPath<T, String>, key: (String) -> String = { $0 }) -> ([T], Bool) {
        var taken = Set(items.map { key($0[keyPath: id]) })
        var seen: Set<String> = []
        var result = items
        var changed = false
        for index in result.indices {
            let current = result[index][keyPath: id]
            if !current.isEmpty, seen.insert(key(current)).inserted { continue }
            let replacement = uniqueID(base: current.isEmpty ? UUID().uuidString.lowercased() : current, taken: taken, key: key)
            result[index][keyPath: id] = replacement
            taken.insert(key(replacement))
            seen.insert(key(replacement))
            changed = true
        }
        return (result, changed)
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
        let previousDomain = sites[index].domain
        var updated = normalizedSite(site)
        updated.updatedAt = Date()
        sites[index] = updated
        saveSites()
        if previousDomain != updated.domain {
            retargetTunnelRoutes(fromSiteDomain: previousDomain, to: updated.domain)
        }
        reconcileTunnelLinks()
    }

    /// Tunnel routes follow a renamed site instead of silently losing their link.
    private func retargetTunnelRoutes(fromSiteDomain oldDomain: String, to newDomain: String) {
        var changed = false
        for index in tunnelRoutes.indices where tunnelRoutes[index].kind == .php {
            if tunnelRoutes[index].linkedSiteDomain == oldDomain {
                tunnelRoutes[index].linkedSiteDomain = newDomain
                changed = true
            }
            if tunnelRoutes[index].localDomain == oldDomain {
                tunnelRoutes[index].localDomain = newDomain
                changed = true
            }
        }
        if changed { saveTunnelRoutes() }
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
        // The ID names the launch agent and log file, so it must never collide with another project's.
        let base = AppProject.defaultID(from: name)
        let project = AppProject(
            id: Self.uniqueID(base: base.isEmpty ? UUID().uuidString.lowercased() : base,
                              taken: Set(appProjects.map(\.sanitizedID)), key: AppProject.sanitizedID),
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
        var route = normalizedTunnelRoute(route)
        let taken = Set(tunnelRoutes.map(\.id))
        if route.id.isEmpty || taken.contains(route.id) {
            route.id = Self.uniqueID(base: route.id.isEmpty ? UUID().uuidString : route.id, taken: taken)
        }
        tunnelRoutes.append(route)
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
        tunnelRoutes = Self.deduplicatingIDs(routes.map(normalizedTunnelRoute), id: \.id).0
        saveTunnelRoutes()
        reconcileTunnelLinks()
    }

    @discardableResult
    public func replaceCloudflareSettings(_ cloudflareSettings: CloudflareSettings) -> Bool {
        settings.cloudflareSettings = NestValidation.normalizedCloudflareSettings(cloudflareSettings)
        return saveSettings()
    }

    public func exportCloudflareSettings() throws -> Data {
        try encoder.encode(settings.cloudflareSettings)
    }

    public func importCloudflareSettings(from data: Data) throws {
        let imported = try decoder.decode(CloudflareSettings.self, from: data)
        var merged = imported
        if merged.apiToken.isEmpty { merged.apiToken = settings.cloudflareSettings.apiToken }
        settings.cloudflareSettings = NestValidation.normalizedCloudflareSettings(merged)
        guard saveSettings() else { throw ConfigurationFailure(saveError(.settings) ?? "Could not save imported settings.") }
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

        appProjects = Self.deduplicatingIDs(updatedProjects.map(normalizedProject), id: \.id, key: AppProject.sanitizedID).0
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        tunnelRoutes = Self.deduplicatingIDs(updatedRoutes.map(normalizedTunnelRoute), id: \.id).0
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

    /// An explicit link wins while its target exists; otherwise routes link by hostname only.
    /// A shared port is not evidence of identity (many dev servers default to 3000/5173).
    public func reconcileTunnelLinks() {
        // Linking against a list that failed to load would drop every link.
        guard !unreadableFiles.contains(.sites), !unreadableFiles.contains(.projects) else { return }
        var updated = tunnelRoutes
        var changed = false

        for index in updated.indices {
            var route = updated[index]

            if route.kind == .php {
                let matchedSite = route.linkedSiteDomain.flatMap { domain in sites.first { $0.domain == domain } }
                    ?? sites.first { $0.domain == route.localDomain }
                    ?? sites.first { $0.domain == "\(route.localDomain).test" }

                let linkedDomain = matchedSite?.domain
                if route.linkedSiteDomain != linkedDomain {
                    route.linkedSiteDomain = linkedDomain
                    changed = true
                }
            } else {
                let matchedProject = route.linkedProjectID.flatMap { id in appProjects.first { $0.id == id } }
                    ?? appProjects.first { $0.hostname == route.localDomain || $0.hostname == route.publicHostname }

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
        // Its results could not all be saved (and the completion flag might never persist,
        // re-running the import over the user's edits on every launch).
        guard unreadableFiles.isDisjoint(with: [.settings, .projects, .tunnelRoutes]) else { return }

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
