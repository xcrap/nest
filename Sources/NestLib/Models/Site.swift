import Foundation

public enum SiteStatus: String, Codable, CaseIterable {
    case running
    case stopped
}

public struct Site: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var domain: String
    public var rootPath: String
    public var documentRoot: String
    public var status: SiteStatus
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        domain: String,
        rootPath: String,
        documentRoot: String = "public",
        status: SiteStatus = .stopped,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.domain = domain
        self.rootPath = rootPath
        self.documentRoot = documentRoot
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The full path to the document root directory.
    public var resolvedDocumentRoot: String {
        if documentRoot == "." {
            return rootPath
        }
        return (rootPath as NSString).appendingPathComponent(documentRoot)
    }

    /// Infer the document root for an imported site: use "public" if present, otherwise ".".
    public static func inferDocumentRoot(rootPath: String, specified: String?) -> String {
        if let specified, !specified.isEmpty {
            return specified
        }
        let publicPath = (rootPath as NSString).appendingPathComponent("public")
        if FileManager.default.fileExists(atPath: publicPath) {
            return "public"
        }
        return "."
    }
}
