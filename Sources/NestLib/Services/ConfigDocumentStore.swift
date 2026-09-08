import Foundation
import Combine

@MainActor
public final class ConfigDocumentStore: ObservableObject {
    public struct Draft {
        public var content: String
        public var baseline: String
        public var existed: Bool
        public var dirty: Bool { content != baseline }
    }
    @Published public private(set) var drafts: [String: Draft] = [:]
    @Published public private(set) var busy = false
    @Published public private(set) var message: String?
    @Published public private(set) var error: String?
    public init() {}

    public func load(path: String, fallback: String = "") {
        guard drafts[path] == nil else { return }
        do {
            let existed = FileManager.default.fileExists(atPath: path)
            let content = existed ? try String(contentsOfFile: path, encoding: .utf8) : fallback
            drafts[path] = Draft(content: content, baseline: content, existed: existed)
        } catch { self.error = error.localizedDescription }
    }
    public func edit(path: String, content: String) {
        drafts[path]?.content = content
        message = nil
        error = nil
    }
    public func discard(path: String) {
        drafts[path] = nil
        message = nil
        error = nil
        load(path: path)
    }
    public func restoreBackup(path: String) {
        do { edit(path: path, content: try String(contentsOfFile: ConfigurationService.backupPath(for: path), encoding: .utf8)) }
        catch { self.error = error.localizedDescription }
    }
    public func save(path: String, operation: (String) async throws -> String) async {
        guard !busy, let draft = drafts[path] else { return }
        busy = true; error = nil; message = nil
        defer { busy = false }
        do {
            let exists = FileManager.default.fileExists(atPath: path)
            let onDisk = exists ? try String(contentsOfFile: path, encoding: .utf8) : ""
            guard exists == draft.existed && (!exists || onDisk == draft.baseline) else {
                throw ConfigurationFailure("This file changed outside the editor. Copy your draft before choosing Discard & Reload.")
            }
            let result = try await operation(draft.content)
            drafts[path] = Draft(content: draft.content, baseline: draft.content, existed: true)
            message = result
        } catch { self.error = error.localizedDescription }
    }
}
