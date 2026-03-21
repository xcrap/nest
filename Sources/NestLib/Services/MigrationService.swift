import Foundation

/// Handles importing legacy site exports and new migration bundles.
public struct MigrationService {
    /// Validate a list of legacy site entries before import.
    public static func validateEntries(_ entries: [LegacySiteEntry], existingDomains: Set<String>) -> [ImportValidationError] {
        var errors: [ImportValidationError] = []
        var seenDomains: Set<String> = []

        for entry in entries {
            if entry.domain.isEmpty {
                errors.append(.missingDomain(siteName: entry.name))
                continue
            }
            if entry.rootPath.isEmpty {
                errors.append(.missingRootPath(siteName: entry.name))
                continue
            }

            let domain = entry.domain.hasSuffix(".test") ? entry.domain : "\(entry.domain).test"

            if existingDomains.contains(domain) || seenDomains.contains(domain) {
                errors.append(.duplicateDomain(domain: domain))
                continue
            }
            seenDomains.insert(domain)

            // Validate document root if specified
            if let docRoot = entry.documentRoot, !docRoot.isEmpty, docRoot != ".", docRoot != "public", docRoot != "web" {
                let fullPath = (entry.rootPath as NSString).appendingPathComponent(docRoot)
                if !FileManager.default.fileExists(atPath: fullPath) {
                    errors.append(.invalidDocumentRoot(siteName: entry.name, path: docRoot))
                }
            }
        }

        return errors
    }

    /// Parse import data into legacy site entries. Supports both v1 format and plain arrays.
    public static func parseImportData(_ data: Data) throws -> [LegacySiteEntry] {
        let decoder = JSONDecoder()

        if let export = try? decoder.decode(LegacySiteExport.self, from: data) {
            return export.sites
        }
        if let array = try? decoder.decode([LegacySiteEntry].self, from: data) {
            return array
        }

        throw NSError(
            domain: "Nest",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unrecognized import format. Expected v1 export or a JSON array of sites."]
        )
    }

    /// Read a migration bundle manifest from a directory.
    public static func readManifest(from directory: URL) throws -> MigrationManifest {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(MigrationManifest.self, from: data)
    }

    /// Read site entries from a migration bundle.
    public static func readBundleSites(from directory: URL, manifest: MigrationManifest) throws -> [LegacySiteEntry] {
        let sitesURL = directory.appendingPathComponent(manifest.siteExportFilename)
        let data = try Data(contentsOf: sitesURL)
        return try parseImportData(data)
    }

    /// List database dump files in a migration bundle.
    public static func listDatabaseDumps(in directory: URL) -> [URL] {
        let dbDir = directory.appendingPathComponent("databases")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dbDir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.filter { $0.pathExtension == "sql" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Generate the mysqldump commands needed to export all databases.
    public static func exportCommands(mysqldumpPath: String, socketPath: String?) -> [String] {
        var base = mysqldumpPath
        if let socket = socketPath {
            base += " --socket=\(socket)"
        }
        base += " -u root"

        return [
            "# List databases:",
            "\(socketPath.map { "\(mysqldumpPath.replacingOccurrences(of: "dump", with: "")) --socket=\($0)" } ?? "mariadb") -u root -e 'SHOW DATABASES;'",
            "",
            "# Export a single database:",
            "\(base) --single-transaction DATABASE_NAME > DATABASE_NAME.sql",
            "",
            "# Export all databases:",
            "\(base) --single-transaction --all-databases > all-databases.sql",
        ]
    }
}
