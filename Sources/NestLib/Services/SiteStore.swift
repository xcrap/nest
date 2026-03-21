import Foundation
import Combine

/// Persists sites and app settings as JSON in the app support directory.
@MainActor
public final class SiteStore: ObservableObject {
    @Published public var sites: [Site] = []
    @Published public var settings: AppSettings

    private let sitesFileURL: URL
    private let settingsFileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        let defaults = AppSettings.defaultSettings()
        let nestDir = AppSettings.nestDataDirectory

        let fm = FileManager.default
        try? fm.createDirectory(atPath: nestDir, withIntermediateDirectories: true)

        self.sitesFileURL = URL(fileURLWithPath: nestDir).appendingPathComponent("sites.json")
        self.settingsFileURL = URL(fileURLWithPath: nestDir).appendingPathComponent("settings.json")

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        let iso8601WithFractional = ISO8601DateFormatter()
        iso8601WithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso8601Plain = ISO8601DateFormatter()
        iso8601Plain.formatOptions = [.withInternetDateTime]
        dec.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            if let date = iso8601WithFractional.date(from: dateString) { return date }
            if let date = iso8601Plain.date(from: dateString) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date: \(dateString)")
        }
        self.decoder = dec

        self.settings = defaults

        loadSettings()
        loadSites()
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

    private func loadSettings() {
        guard let data = try? Data(contentsOf: settingsFileURL) else { return }
        if let loaded = try? decoder.decode(AppSettings.self, from: data) {
            settings = loaded
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
    }

    public func deleteSite(id: String) {
        sites.removeAll { $0.id == id }
        saveSites()
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
}
