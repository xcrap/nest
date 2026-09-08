import Foundation
import NestLib

@MainActor
enum ReliabilityTests {
    static func runAll() async -> (passed: Int, failed: Int) {
        var passed = 0, failed = 0
        func check(_ value: Bool, _ message: String) {
            if value { passed += 1 } else { failed += 1; print("  FAIL: \(message)") }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nest-reliability-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let config = directory.appendingPathComponent("config").path
            let renderer = ConfigRenderer(configDirectory: config, frankenphpLogPath: "")
            try renderer.writeAll(sites: [])
            let snippet = config + "/snippets/php-app"
            try "# custom snippet".write(toFile: snippet, atomically: true, encoding: .utf8)
            try "# custom security".write(toFile: renderer.securityConfPath, atomically: true, encoding: .utf8)
            let custom = config + "/overrides/custom.caddy"
            try "# custom override".write(toFile: custom, atomically: true, encoding: .utf8)
            try renderer.writeAll(sites: [])
            check(try String(contentsOfFile: snippet, encoding: .utf8) == "# custom snippet", "regeneration preserves custom snippets")
            check(try String(contentsOfFile: renderer.securityConfPath, encoding: .utf8) == "# custom security", "regeneration preserves security settings")
            check(try String(contentsOfFile: custom, encoding: .utf8) == "# custom override", "regeneration preserves overrides")
            check(renderer.render(sites: []).contains("overrides/*.caddy"), "generated file imports custom overrides")
            let file = directory.appendingPathComponent("editable.conf").path
            try "old".write(toFile: file, atomically: true, encoding: .utf8)
            let service = ConfigurationService(command: { _, _ in .init(status: 0, output: "") }, reload: { _ in throw ConfigurationFailure("rejected reload") })
            do {
                try await service.save(content: "new", path: file, apply: { _ in throw ConfigurationFailure("rejected") })
                check(false, "rejected apply must throw")
            } catch { check(true, "rejected apply throws") }
            check(try String(contentsOfFile: file, encoding: .utf8) == "old", "rejected apply restores previous file")
            check(try String(contentsOfFile: ConfigurationService.backupPath(for: file), encoding: .utf8) == "old", "backup retains previous version")
            check(!ConfigurationService.backupPath(for: snippet).hasPrefix(config + "/snippets/"), "backup is outside live snippet glob")
            try await service.save(content: "# changed", path: snippet)
            check(try FileManager.default.contentsOfDirectory(atPath: config + "/snippets").count == 1, "saving does not add an imported backup")
            let originalCaddy = try String(contentsOfFile: renderer.caddyfilePath, encoding: .utf8)
            var settings = AppSettings(caddyConfigDirectory: config)
            settings.runtimePaths.frankenphpBinary = "/test/frankenphp"
            let site = Site(name: "New", domain: "new.test", rootPath: directory.path, documentRoot: ".", status: .running)
            do { _ = try await service.applyCaddy(settings: settings, sites: [site], running: true); check(false, "reload rejection propagates") }
            catch { check(error.localizedDescription == "rejected reload", "reload error is preserved") }
            check(try String(contentsOfFile: renderer.caddyfilePath, encoding: .utf8) == originalCaddy, "Caddy apply failure restores disk config")
            let invalid = ConfigurationService(command: { _, _ in .init(status: 1, output: "bad syntax") })
            do { _ = try await invalid.applyCaddy(settings: settings, sites: [site], running: false); check(false, "validation failure propagates") }
            catch { check(error.localizedDescription.contains("bad syntax"), "validator output reaches caller") }
            check(try String(contentsOfFile: renderer.caddyfilePath, encoding: .utf8) == originalCaddy, "invalid config never replaces current config")
            let documents = ConfigDocumentStore()
            documents.load(path: file)
            documents.edit(path: file, content: "draft")
            documents.load(path: snippet)
            documents.load(path: file)
            check(documents.drafts[file]?.content == "draft", "switching documents preserves edits")
            await documents.save(path: file) { _ in throw ConfigurationFailure("disk full") }
            check(documents.message == nil && documents.error == "disk full", "failed save never reports Saved")
            check(documents.drafts[file]?.dirty == true, "failed save retains dirty draft")
            try "external edit".write(toFile: file, atomically: true, encoding: .utf8)
            var wrote = false
            await documents.save(path: file) { _ in wrote = true; return "Saved" }
            check(!wrote && documents.error?.contains("outside the editor") == true, "external modification is protected")
            let serialFile = directory.appendingPathComponent("serial.conf").path
            try "original".write(toFile: serialFile, atomically: true, encoding: .utf8)
            let first = Task {
                try? await service.save(content: "rejected", path: serialFile, apply: { _ in
                    try await Task.sleep(for: .milliseconds(80))
                    throw ConfigurationFailure("reject first write")
                })
            }
            try await Task.sleep(for: .milliseconds(20))
            let second = Task { try await service.save(content: "accepted", path: serialFile) }
            await first.value
            try await second.value
            check(try String(contentsOfFile: serialFile, encoding: .utf8) == "accepted", "queued save is not overwritten by earlier rollback")

            let blocked = directory.appendingPathComponent("blocked").path
            try "not a directory".write(toFile: blocked, atomically: true, encoding: .utf8)
            do { try await service.save(content: "x", path: blocked + "/file"); check(false, "write failure propagates") }
            catch { check(true, "write failure propagates") }
            settings.cloudflareSettings = CloudflareSettings(tunnelName: "test", configPath: directory.appendingPathComponent("tunnel.yaml").path, credentialsFilePath: directory.appendingPathComponent("credentials.json").path)
            settings.runtimePaths.cloudflaredBinary = "/test/cloudflared"
            try "old tunnel".write(toFile: settings.cloudflareSettings.configPath, atomically: true, encoding: .utf8)
            do {
                _ = try await service.applyTunnel(settings: settings, routes: [], sites: [], projects: [], running: true, push: false, restart: { throw ConfigurationFailure("connector restart failed") })
                check(false, "failed connector restart propagates")
            } catch { check(error.localizedDescription.contains("connector restart failed"), "connector failure reaches caller") }
            check(try String(contentsOfFile: settings.cloudflareSettings.configPath, encoding: .utf8) == "old tunnel", "connector failure restores old YAML")
            var restarted = false
            do {
                _ = try await service.applyTunnel(settings: settings, routes: [], sites: [], projects: [], running: true, push: true, restart: { restarted = true }, pushConfiguration: { throw ConfigurationFailure("API unavailable") })
                check(false, "failed remote push propagates")
            } catch { check(restarted && error.localizedDescription.contains("Local configuration saved"), "partial remote failure reports successful local apply") }
        } catch { check(false, "configuration tests: \(error)") }

        let project = AppProject(name: "Test", hostname: "test.local", directory: directory.path, port: 49123, command: "test")
        let plan = ProjectLaunchPlanner.plan(for: project)
        var started = false, stopped = false
        let conflict = ProjectLifecycleService(listeners: { _ in [123] }, ownedPIDs: { _ in [] }, startAgent: { _ in started = true; return .init(status: 0, output: "") }, stopAgent: { _ in stopped = true; return .init(status: 0, output: "") })
        let state = conflict.start(plan, timeout: 0)
        check(!state.running && state.error?.contains("another process") == true, "occupied port is a conflict")
        check(!started, "conflict does not launch a project")
        _ = conflict.stop(plan, timeout: 0)
        check(!stopped, "stopping an unrelated listener does not kill it")
        var owned: Set<Int32> = [123]
        let managed = ProjectLifecycleService(listeners: { _ in owned.isEmpty ? [] : [123] }, ownedPIDs: { _ in owned }, stopAgent: { _ in owned = []; return .init(status: 0, output: "") })
        check(managed.state(plan).running, "owned listener is running")
        check(!managed.stop(plan, timeout: 0).running, "managed process stops through its launch agent")
        let verbose = await SystemProcess.captureAsync("/usr/bin/head", arguments: ["-c", "2097152", "/dev/zero"], timeout: 5)
        check(verbose.status == 0 && verbose.output.utf8.count == 1_048_576, "verbose command completes with bounded output")
        let deadline = Date()
        let slow = await SystemProcess.captureAsync("/bin/sleep", arguments: ["10"], timeout: 0.1)
        check(slow.status == 124 && Date().timeIntervalSince(deadline) < 2, "command deadline terminates child")
        let cancelled = Task { await SystemProcess.captureAsync("/bin/sleep", arguments: ["10"]) }
        try? await Task.sleep(for: .milliseconds(50))
        cancelled.cancel()
        check(await cancelled.value.status == 124, "cancelling an async command terminates it")
        do {
            let storeDirectory = directory.appendingPathComponent("store")
            let secret = "synthetic-test-token"
            let credentials = MemoryCredentialStore()
            let store = SiteStore(dataDirectory: storeDirectory, defaults: AppSettings(), runOneTimeMigrations: false, credentialStore: credentials)
            var cf = CloudflareSettings(apiToken: secret, tunnelName: "fixture")
            check(store.replaceCloudflareSettings(cf), "credential save succeeds")
            let persisted = try String(contentsOf: storeDirectory.appendingPathComponent("settings.json"), encoding: .utf8)
            check(!persisted.contains(secret) && !persisted.contains("apiToken"), "persisted settings contain no API token")
            check(try credentials.load() == secret, "token is stored in credential store")
            check(!String(decoding: try store.exportCloudflareSettings(), as: UTF8.self).contains(secret), "export excludes token")
            let reloaded = SiteStore(dataDirectory: storeDirectory, defaults: AppSettings(), runOneTimeMigrations: false, credentialStore: credentials)
            check(reloaded.settings.cloudflareSettings.apiToken == secret, "token is restored from credential store")
            cf.apiToken = ""
            try reloaded.importCloudflareSettings(from: JSONEncoder().encode(cf))
            check(reloaded.settings.cloudflareSettings.apiToken == secret, "nonsecret import preserves existing token")
            let legacyDirectory = directory.appendingPathComponent("legacy")
            try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as! [String: Any]
            json["cloudflareSettings"] = ["apiToken": secret]
            try JSONSerialization.data(withJSONObject: ["schemaVersion": StoreSchema.currentVersion, "savedAt": "2026-09-07T10:00:00Z", "payload": json]).write(to: legacyDirectory.appendingPathComponent("settings.json"))
            let migrated = SiteStore(dataDirectory: legacyDirectory, defaults: AppSettings(), runOneTimeMigrations: false, credentialStore: MemoryCredentialStore())
            check(migrated.settings.cloudflareSettings.apiToken == secret, "legacy plaintext token is migrated")
            check(!(try String(contentsOf: legacyDirectory.appendingPathComponent("settings.json"), encoding: .utf8)).contains(secret), "successful migration strips plaintext")
            let lockedDirectory = directory.appendingPathComponent("locked-legacy")
            try FileManager.default.createDirectory(at: lockedDirectory, withIntermediateDirectories: true)
            let legacyData = try JSONSerialization.data(withJSONObject: ["schemaVersion": StoreSchema.currentVersion, "savedAt": "2026-09-07T10:00:00Z", "payload": json])
            try legacyData.write(to: lockedDirectory.appendingPathComponent("settings.json"))
            let locked = SiteStore(dataDirectory: lockedDirectory, defaults: AppSettings(), runOneTimeMigrations: false, credentialStore: DeniedCredentials())
            check(locked.lastSaveError != nil, "failed migration is reported")
            check(try Data(contentsOf: lockedDirectory.appendingPathComponent("settings.json")) == legacyData, "failed Keychain migration preserves original token on disk")

            let deniedStore = SiteStore(dataDirectory: directory.appendingPathComponent("denied"), defaults: AppSettings(), runOneTimeMigrations: false, credentialStore: DeniedCredentials())
            check(!deniedStore.replaceCloudflareSettings(CloudflareSettings(apiToken: secret)), "Keychain error fails save")
            check(deniedStore.lastSaveError?.contains("Keychain unavailable") == true, "Keychain error is visible")
        } catch { check(false, "credential tests: \(error)") }
        return (passed, failed)
    }
    private struct DeniedCredentials: CredentialStore {
        func load() throws -> String { "" }
        func save(_ token: String) throws { throw ConfigurationFailure("Keychain unavailable") }
    }
}
