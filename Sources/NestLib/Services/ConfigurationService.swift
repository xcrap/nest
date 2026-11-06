import Foundation

public struct ConfigurationFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum ApplyState: Equatable {
    case unverified, pending, applying, applied(String), failed(String)
    public var label: String {
        switch self {
        case .unverified: return "Configuration not yet verified"
        case .pending: return "Pending changes"
        case .applying: return "Applying…"
        case .applied(let message): return message
        case .failed(let message): return "Failed: \(message)"
        }
    }
    public var isBusy: Bool { if case .applying = self { return true }; return false }
}

/// Serializes writes from the editor and generated configuration workflows.
/// Command/network boundaries are injectable so failures can be tested without live services.
public actor ConfigurationService {
    public static let shared = ConfigurationService()
    public typealias Command = (String, [String]) async -> CommandResult
    public typealias Reload = (String) async throws -> Void
    private let command: Command
    private let reload: Reload

    /// Caddy/editor files and the cloudflared config are independent, so a slow connector
    /// restart never holds up a site toggle.
    private enum Lane { case files, tunnel }
    private var locked: Set<Lane> = []
    private var waiters: [Lane: [CheckedContinuation<Void, Never>]] = [:]
    private func acquire(_ lane: Lane) async {
        if !locked.contains(lane) { locked.insert(lane); return }
        await withCheckedContinuation { waiters[lane, default: []].append($0) }
    }
    private func release(_ lane: Lane) {
        if waiters[lane]?.isEmpty ?? true { locked.remove(lane) }
        else { waiters[lane]!.removeFirst().resume() }
    }

    public init(command: @escaping Command = { await SystemProcess.captureAsync($0, arguments: $1) },
                reload: @escaping Reload = ConfigurationService.reloadCaddy) {
        self.command = command
        self.reload = reload
    }

    public static func reloadCaddy(_ content: String) async throws {
        var request = URLRequest(url: URL(string: "http://localhost:2019/load")!)
        request.timeoutInterval = 15
        request.httpMethod = "POST"
        request.setValue("text/caddyfile", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(content.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ConfigurationFailure("Caddy rejected the reload: \(String(decoding: data, as: UTF8.self))")
        }
    }

    public nonisolated static func backupPath(for path: String) -> String {
        let file = URL(fileURLWithPath: path)
        let parent = file.deletingLastPathComponent()
        return parent.deletingLastPathComponent().appendingPathComponent(".nest-backups")
            .appendingPathComponent(parent.lastPathComponent + "-" + file.lastPathComponent + ".previous").path
    }

    /// Call only after validation. A rejected apply restores the previous file.
    public func save(content: String, path: String, apply: Reload? = nil) async throws {
        await acquire(.files)
        defer { release(.files) }
        try await commit(content: content, path: path, apply: apply)
    }

    private func commit(content: String, path: String, apply: Reload? = nil) async throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = FileManager.default.fileExists(atPath: path) ? try Data(contentsOf: url) : nil
        let new = Data(content.utf8)
        // Saving unchanged content rewrites nothing, so the backup keeps the real previous
        // version for "Restore Previous Version". The apply still runs (e.g. a re-apply).
        let changed = old != new
        if changed {
            if let old {
                let backup = URL(fileURLWithPath: Self.backupPath(for: path))
                try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                try old.write(to: backup, options: .atomic)
            }
            try new.write(to: url, options: .atomic)
        }
        do {
            try await apply?(content)
        } catch {
            guard changed else { throw error }
            do {
                if let old { try old.write(to: url, options: .atomic) }
                else { try FileManager.default.removeItem(at: url) }
            } catch let restoreError {
                throw ConfigurationFailure("Apply failed: \(error.localizedDescription). Restore also failed: \(restoreError.localizedDescription). Backup: \(Self.backupPath(for: path))")
            }
            throw error
        }
    }

    public func applyCaddy(settings: AppSettings, sites: [Site], running: Bool) async throws -> String {
        await acquire(.files)
        defer { release(.files) }
        let renderer = ConfigRenderer(configDirectory: settings.caddyConfigDirectory, frankenphpLogPath: settings.runtimePaths.frankenphpLog)
        let issues = renderer.validationIssues(sites: sites)
        guard issues.isEmpty else { throw ConfigurationFailure(issues.joined(separator: " ")) }
        try renderer.writeSupportFiles()
        let content = renderer.render(sites: sites)
        try await validateCaddy(content, binary: settings.runtimePaths.frankenphpBinary)
        try await commit(content: content, path: renderer.caddyfilePath, apply: running ? reload : nil)
        return running ? "Applied to Caddy" : "Saved • FrankenPHP stopped"
    }

    public func validateCaddy(_ content: String, binary: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nest-validate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let candidate = directory.appendingPathComponent("Caddyfile")
        try content.write(to: candidate, atomically: true, encoding: .utf8)
        let result = await command(binary, ["validate", "--config", candidate.path, "--adapter", "caddyfile"])
        guard result.status == 0 else { throw ConfigurationFailure("Invalid Caddy configuration: \(result.output)") }
    }

    public func saveCaddySupport(content: String, path: String, settings: AppSettings, running: Bool) async throws -> String {
        await acquire(.files)
        defer { release(.files) }
        var config = settings.caddyConfigDirectory
        while config.count > 1 && config.hasSuffix("/") { config.removeLast() }
        let caddyPath = config + "/Caddyfile"
        let active = try String(contentsOfFile: caddyPath, encoding: .utf8)
        // Validate an isolated copy of all imports; never put a candidate in a live wildcard directory.
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("nest-editor-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: directory) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // Only these exact live paths are redirected to staged copies. Every other path, such as
        // another file an override imports from the config directory, keeps pointing at the live file.
        var mappings: [(live: String, staged: String)] = []
        for name in ["snippets", "security.conf", "overrides"] {
            let live = config + "/" + name
            // The snippets directory is required (it holds php-app); the others are optional.
            guard name == "snippets" || fm.fileExists(atPath: live) else { continue }
            try fm.copyItem(atPath: live, toPath: directory.path + "/" + name)
            mappings.append((live, directory.path + "/" + name))
        }
        let stagedPath = path.hasPrefix(config + "/")
            ? directory.path + "/" + String(path.dropFirst(config.count + 1))
            : directory.path + "/external/" + (path as NSString).lastPathComponent
        if !mappings.contains(where: { path == $0.live || path.hasPrefix($0.live + "/") }) {
            mappings.append((path, stagedPath))
        }
        try fm.createDirectory(atPath: (stagedPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try content.write(toFile: stagedPath, atomically: true, encoding: .utf8)
        let files = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        while let file = files?.nextObject() as? URL {
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
               let text = try? String(contentsOf: file, encoding: .utf8) {
                let redirected = Self.redirectingPaths(in: text, mappings)
                if redirected != text { try redirected.write(to: file, atomically: true, encoding: .utf8) }
            }
        }
        try await validateCaddy(Self.redirectingPaths(in: active, mappings), binary: settings.runtimePaths.frankenphpBinary)
        let reload = self.reload
        try await commit(content: content, path: path, apply: running ? { _ in try await reload(active) } : nil)
        return running ? "Saved and applied" : "Saved • FrankenPHP stopped"
    }

    /// Replaces each live path with its staged copy only where it appears as a whole path, or as
    /// a prefix followed by `/`: `/opt/homebrew/etc2` or `security.conf.bak` are left intact.
    nonisolated static func redirectingPaths(in text: String, _ mappings: [(live: String, staged: String)]) -> String {
        var result = text
        for mapping in mappings.sorted(by: { $0.live.count > $1.live.count }) {
            let pattern = "(?<![A-Za-z0-9._~/-])" + NSRegularExpression.escapedPattern(for: mapping.live) + "(?![A-Za-z0-9._~-])"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: mapping.staged)
            )
        }
        return result
    }

    public func applyTunnel(settings: AppSettings, routes: [TunnelRoute], sites: [Site], projects: [AppProject],
                            running: Bool, push: Bool,
                            restart: @escaping () async throws -> Void,
                            pushConfiguration: (() async throws -> Void)? = nil) async throws -> String {
        try await applyTunnelLocally(settings: settings, routes: routes, sites: sites, projects: projects,
                                     running: running, restart: restart)
        // Publishing (DNS records + ingress), not just the ingress push, so the app and nestctl behave alike.
        let pushAction = pushConfiguration ?? {
            try await CloudflareService.publishTunnel(settings: settings.cloudflareSettings, routes: routes, sites: sites, projects: projects)
        }
        // A remote push is not rolled back implicitly: report its partial outcome honestly.
        // It runs outside the lock so a slow network never blocks the next local apply.
        if push {
            do { try await pushAction() }
            catch { throw ConfigurationFailure("Local configuration saved\(running ? " and connector restarted" : ""); Cloudflare push failed: \(error.localizedDescription)") }
        }
        return running ? "Applied • connector restarted\(push ? " • pushed to Cloudflare" : "")" : "Saved\(push ? " and pushed" : "") • connector stopped"
    }

    private func applyTunnelLocally(settings: AppSettings, routes: [TunnelRoute], sites: [Site], projects: [AppProject],
                                    running: Bool, restart: @escaping () async throws -> Void) async throws {
        await acquire(.tunnel)
        defer { release(.tunnel) }
        let renderer = TunnelConfigRenderer(settings: settings.cloudflareSettings)
        let issues = renderer.validationIssues(routes: routes, sites: sites, projects: projects)
        guard issues.isEmpty else { throw ConfigurationFailure(issues.joined(separator: " ")) }
        let content = renderer.render(routes: routes, sites: sites, projects: projects)
        let candidate = FileManager.default.temporaryDirectory.appendingPathComponent("nest-tunnel-\(UUID().uuidString).yaml")
        defer { try? FileManager.default.removeItem(at: candidate) }
        try content.write(to: candidate, atomically: true, encoding: .utf8)
        let check = await command(settings.runtimePaths.cloudflaredBinary, ["--config", candidate.path, "tunnel", "ingress", "validate"])
        guard check.status == 0 else { throw ConfigurationFailure("Invalid tunnel configuration: \(check.output)") }
        var attemptedRestart = false
        do {
            try await commit(content: content, path: settings.cloudflareSettings.configPath, apply: { _ in
                if running { attemptedRestart = true; try await restart() }
            })
        } catch {
            if attemptedRestart {
                do { try await restart() }
                catch let recoveryError {
                    throw ConfigurationFailure("\(error.localizedDescription). Restarting the previous configuration also failed: \(recoveryError.localizedDescription)")
                }
            }
            throw error
        }
    }
}
