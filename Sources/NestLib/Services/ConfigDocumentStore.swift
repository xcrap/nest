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
    /// Unsaved Cloudflare settings; kept here so switching tabs does not discard them.
    @Published public var cloudflareDraft: CloudflareSettings?
    /// Unsaved Settings → Paths edits (including Auto-Detect results); kept here so switching
    /// tabs or sections does not discard them.
    @Published public var runtimePathsDraft: RuntimePaths?
    @Published public private(set) var busy = false
    @Published public private(set) var message: String?
    @Published public private(set) var error: String?
    /// The file `message` and `error` belong to; a status never shows on another file.
    @Published public private(set) var statusPath: String?
    public init() {}

    public func message(for path: String) -> String? { statusPath == path ? message : nil }
    public func error(for path: String) -> String? { statusPath == path ? error : nil }

    /// True when any config file editor has unsaved changes.
    public var hasDirtyEditors: Bool { drafts.values.contains(where: \.dirty) }

    /// True when the Paths draft differs from the saved paths.
    public func hasUnsavedRuntimePaths(comparedTo saved: RuntimePaths) -> Bool {
        runtimePathsDraft.map { $0 != saved } ?? false
    }

    public func load(path: String, fallback: String = "") {
        if statusPath != path { clearStatus() }
        guard drafts[path] == nil else { return }
        do {
            let existed = FileManager.default.fileExists(atPath: path)
            let content = existed ? try String(contentsOfFile: path, encoding: .utf8) : fallback
            drafts[path] = Draft(content: content, baseline: content, existed: existed)
        } catch { report(error: error.localizedDescription, for: path) }
    }
    public func edit(path: String, content: String) {
        drafts[path]?.content = content
        clearStatus()
    }
    public func discard(path: String) {
        drafts[path] = nil
        clearStatus()
        load(path: path)
    }
    public func restoreBackup(path: String) {
        do { edit(path: path, content: try String(contentsOfFile: ConfigurationService.backupPath(for: path), encoding: .utf8)) }
        catch { report(error: error.localizedDescription, for: path) }
    }
    public func save(path: String, operation: (String) async throws -> String) async {
        guard !busy, let draft = drafts[path] else { return }
        busy = true
        clearStatus()
        statusPath = path
        defer { busy = false }
        do {
            let exists = FileManager.default.fileExists(atPath: path)
            let onDisk = exists ? try String(contentsOfFile: path, encoding: .utf8) : ""
            guard exists == draft.existed && (!exists || onDisk == draft.baseline) else {
                throw ConfigurationFailure("This file changed outside the editor. Copy your draft before choosing Discard & Reload.")
            }
            let result = try await operation(draft.content)
            drafts[path] = Draft(content: draft.content, baseline: draft.content, existed: true)
            statusPath = path
            message = result
        } catch { report(error: error.localizedDescription, for: path) }
    }

    private func clearStatus() {
        if message != nil { message = nil }
        if error != nil { error = nil }
        if statusPath != nil { statusPath = nil }
    }

    private func report(error description: String, for path: String) {
        statusPath = path
        error = description
    }
}
