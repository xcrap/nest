import Foundation

public struct ParkedFolderCandidate: Equatable {
    public var name: String
    public var domain: String
    public var rootPath: String
    public var documentRoot: String

    public init(name: String, domain: String, rootPath: String, documentRoot: String) {
        self.name = name
        self.domain = domain
        self.rootPath = rootPath
        self.documentRoot = documentRoot
    }
}

public struct ParkedFolderImportSummary: Equatable {
    public var imported: [Site]
    public var skippedExistingDomains: [String]
    public var skippedInvalidFolders: [String]

    public init(
        imported: [Site] = [],
        skippedExistingDomains: [String] = [],
        skippedInvalidFolders: [String] = []
    ) {
        self.imported = imported
        self.skippedExistingDomains = skippedExistingDomains
        self.skippedInvalidFolders = skippedInvalidFolders
    }
}

public enum ParkedFolderScanner {
    public static func scan(directory: URL, existingDomains: Set<String> = []) -> (candidates: [ParkedFolderCandidate], skippedExisting: [String], skippedInvalid: [String]) {
        let folders = projectFolders(in: directory)
        var candidates: [ParkedFolderCandidate] = []
        var skippedExisting: [String] = []
        var skippedInvalid: [String] = []
        var seenDomains = existingDomains

        for folder in folders {
            let name = folder.lastPathComponent
            let domain = NestValidation.normalizedDomain(slug(from: name), defaultTLD: "test")

            guard NestValidation.domainIssues(domain, field: "Domain", requiredTLD: "test").isEmpty else {
                skippedInvalid.append(folder.path)
                continue
            }
            guard !seenDomains.contains(domain) else {
                skippedExisting.append(domain)
                continue
            }

            let documentRoot = inferredDocumentRoot(for: folder)
            let candidate = ParkedFolderCandidate(
                name: displayName(from: name),
                domain: domain,
                rootPath: folder.path,
                documentRoot: documentRoot
            )

            guard NestValidation.siteIssues(Site(name: candidate.name, domain: candidate.domain, rootPath: candidate.rootPath, documentRoot: candidate.documentRoot)).isEmpty else {
                skippedInvalid.append(folder.path)
                continue
            }

            seenDomains.insert(domain)
            candidates.append(candidate)
        }

        return (
            candidates.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            skippedExisting.sorted(),
            skippedInvalid.sorted()
        )
    }

    private static func projectFolders(in directory: URL) -> [URL] {
        if looksLikeProject(directory) {
            return [directory]
        }

        let children = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return children.filter { child in
            (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && looksLikeProject(child)
        }
    }

    private static func looksLikeProject(_ directory: URL) -> Bool {
        let names = Set(((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []))
        return names.contains("public")
            || names.contains("web")
            || names.contains("composer.json")
            || names.contains("artisan")
            || names.contains("index.php")
    }

    private static func inferredDocumentRoot(for directory: URL) -> String {
        let publicPath = directory.appendingPathComponent("public").path
        if FileManager.default.fileExists(atPath: publicPath) {
            return "public"
        }

        let webPath = directory.appendingPathComponent("web").path
        if FileManager.default.fileExists(atPath: webPath) {
            return "web"
        }

        return "."
    }

    private static func slug(from value: String) -> String {
        let lowered = value.lowercased()
        let replaced = lowered.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        return replaced.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func displayName(from value: String) -> String {
        let words = value
            .replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
            .split(separator: " ")
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst()
            }
        return words.isEmpty ? value : words.joined(separator: " ")
    }
}
