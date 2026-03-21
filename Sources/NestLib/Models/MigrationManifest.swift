import Foundation

// MARK: - Legacy Export Format (v1)

/// The legacy site export format used by the Electron+Go app.
public struct LegacySiteExport: Codable {
    public var version: Int
    public var exportedAt: String
    public var sites: [LegacySiteEntry]

    public init(version: Int, exportedAt: String, sites: [LegacySiteEntry]) {
        self.version = version
        self.exportedAt = exportedAt
        self.sites = sites
    }
}

public struct LegacySiteEntry: Codable {
    public var name: String
    public var domain: String
    public var rootPath: String
    public var documentRoot: String?

    public init(name: String, domain: String, rootPath: String, documentRoot: String? = nil) {
        self.name = name
        self.domain = domain
        self.rootPath = rootPath
        self.documentRoot = documentRoot
    }
}

// MARK: - New Migration Bundle Format

/// Manifest for the Swift-era migration bundle.
public struct MigrationManifest: Codable {
    public var appVersion: String
    public var exportDate: String
    public var sourceAppVersion: String?
    public var siteExportFilename: String
    public var databaseDumps: [DatabaseDumpEntry]
    public var configNotes: String?

    public init(
        appVersion: String,
        exportDate: String = ISO8601DateFormatter().string(from: Date()),
        sourceAppVersion: String? = nil,
        siteExportFilename: String = "sites.json",
        databaseDumps: [DatabaseDumpEntry] = [],
        configNotes: String? = nil
    ) {
        self.appVersion = appVersion
        self.exportDate = exportDate
        self.sourceAppVersion = sourceAppVersion
        self.siteExportFilename = siteExportFilename
        self.databaseDumps = databaseDumps
        self.configNotes = configNotes
    }
}

public struct DatabaseDumpEntry: Codable {
    public var name: String
    public var filename: String

    public init(name: String, filename: String) {
        self.name = name
        self.filename = filename
    }
}

// MARK: - Import Validation

public enum ImportValidationError: LocalizedError, Equatable {
    case missingDomain(siteName: String)
    case missingRootPath(siteName: String)
    case invalidDocumentRoot(siteName: String, path: String)
    case duplicateDomain(domain: String)

    public var errorDescription: String? {
        switch self {
        case .missingDomain(let name):
            return "Site '\(name)' is missing a domain."
        case .missingRootPath(let name):
            return "Site '\(name)' is missing a root path."
        case .invalidDocumentRoot(let name, let path):
            return "Site '\(name)' has an invalid document root: \(path)"
        case .duplicateDomain(let domain):
            return "Duplicate domain: \(domain)"
        }
    }
}
