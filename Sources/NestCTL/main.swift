import Foundation
import NestLib

@main
struct NestCTL {
    @MainActor
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            usage()
            exit(64)
        }

        if ["help", "--help", "-h"].contains(command) { usage(); return }
        let store = SiteStore()
        if let error = store.lastSaveError { fputs("\(error)\n", stderr); exit(1) }

        do {
            switch command {
            case "start":
                try await start(arguments.dropFirst().first ?? "all", store: store)
            case "stop":
                try await stop(arguments.dropFirst().first ?? "all")
            case "reload":
                try await reload(store: store)
            case "render":
                render(arguments.dropFirst().first ?? "all", store: store)
            case "doctor":
                doctor(store: store)
            case "push-cloudflare":
                try await pushCloudflare(store: store)
            case "help", "--help", "-h":
                usage()
            default:
                print("Unknown command: \(command)")
                usage()
                exit(64)
            }
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func usage() {
        print("""
        Usage:
          nestctl start [frankenphp|mariadb|cloudflared|all]
          nestctl stop [frankenphp|mariadb|cloudflared|all]
          nestctl reload
          nestctl render [caddy|cloudflared|all]
          nestctl doctor
          nestctl push-cloudflare
        """)
    }

    @MainActor
    private static func start(_ target: String, store: SiteStore) async throws {
        switch target {
        case "frankenphp":
            let ready = await SystemProcess.captureAsync("/usr/bin/curl", arguments: ["--silent", "--fail", "--max-time", "2", "--output", "/dev/null", "http://localhost:2019/config/"])
            _ = try await ConfigurationService.shared.applyCaddy(settings: store.settings, sites: store.sites, running: ready.status == 0)
            try runBrew(.start, service: "frankenphp")
        case "mariadb":
            try runBrew(.start, service: "mariadb")
        case "cloudflared":
            try await applyCloudflared(store: store, start: true, push: false)
        case "all":
            try await start("frankenphp", store: store)
            try await start("mariadb", store: store)
            try await start("cloudflared", store: store)
        default:
            throw CLIError.invalidTarget(target)
        }
    }

    @MainActor
    private static func stop(_ target: String) async throws {
        switch target {
        case "frankenphp", "mariadb":
            try runBrew(.stop, service: target)
        case "cloudflared":
            let result = await Task.detached { LaunchAgentService.stop(label: ProcessController.cloudflaredLaunchAgentLabel) }.value
            guard result.status == 0 else { throw CLIError.requestFailed(result.output) }
        case "all":
            for service in ["cloudflared", "frankenphp", "mariadb"] { try await stop(service) }
        default: throw CLIError.invalidTarget(target)
        }
        print("Stopped managed service: \(target). Externally managed processes are left running.")
    }

    @MainActor
    private static func reload(store: SiteStore) async throws {
        let message = try await ConfigurationService.shared.applyCaddy(settings: store.settings, sites: store.sites, running: true)
        print(message)
    }

    @MainActor
    private static func render(_ target: String, store: SiteStore) {
        switch target {
        case "caddy":
            print(caddyRenderer(store: store).render(sites: store.sites))
        case "cloudflared":
            print(tunnelRenderer(store: store).render(routes: store.tunnelRoutes, sites: store.sites, projects: store.appProjects))
        case "all":
            print("# Caddyfile")
            print(caddyRenderer(store: store).render(sites: store.sites))
            print("\n# cloudflared")
            print(tunnelRenderer(store: store).render(routes: store.tunnelRoutes, sites: store.sites, projects: store.appProjects))
        default:
            print("Unknown render target: \(target)")
        }
    }

    @MainActor
    private static func doctor(store: SiteStore) {
        let runtimeIssues = store.settings.runtimePaths.validate()
        if runtimeIssues.isEmpty {
            print("[ok] Runtime paths")
        } else {
            for issue in runtimeIssues {
                print("[error] \(issue)")
            }
        }

        for error in store.persistenceErrors {
            print("[warning] \(error)")
        }

        for check in PrerequisiteChecker.checkAll() {
            let status = check.passed ? "ok" : check.severity.rawValue
            print("[\(status)] \(check.name): \(check.detail)")
            for command in check.fixCommands {
                print("  fix: \(command)")
            }
        }
    }

    @MainActor
    private static func pushCloudflare(store: SiteStore) async throws {
        try await applyCloudflared(store: store, start: false, push: true)
    }

    @MainActor
    private static func applyCloudflared(store: SiteStore, start: Bool, push: Bool) async throws {
        let settings = store.settings
        let running = await Task.detached { LaunchAgentService.isRunning(label: ProcessController.cloudflaredLaunchAgentLabel) }.value
        let message = try await ConfigurationService.shared.applyTunnel(settings: settings, routes: store.tunnelRoutes,
            sites: store.sites, projects: store.appProjects, running: start || running, push: push,
            restart: { try await ProcessController.restartConnector(settings: settings) })
        print(message)
    }

    @MainActor
    private static func caddyRenderer(store: SiteStore) -> ConfigRenderer {
        ConfigRenderer(
            configDirectory: store.settings.caddyConfigDirectory,
            frankenphpLogPath: store.settings.runtimePaths.frankenphpLog
        )
    }

    @MainActor
    private static func tunnelRenderer(store: SiteStore) -> TunnelConfigRenderer {
        TunnelConfigRenderer(settings: store.settings.cloudflareSettings)
    }

    private static func runBrew(_ action: BrewServiceAction, service: String) throws {
        guard FileManager.default.isExecutableFile(atPath: BrewServiceController.brewPath) else {
            throw CLIError.requestFailed("Homebrew is not available at \(BrewServiceController.brewPath).")
        }
        let result = SystemProcess.capture(
            BrewServiceController.brewPath,
            arguments: ["services", action.rawValue, service], timeout: 120
        )
        guard result.status == 0 else {
            throw CLIError.requestFailed(result.output.isEmpty ? "brew services \(action.rawValue) \(service) failed." : result.output)
        }
        print("\(action.rawValue.capitalized)ed \(service).")
    }

    private enum CLIError: LocalizedError {
        case invalidTarget(String)
        case requestFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidTarget(let target):
                return "Invalid target: \(target)"
            case .requestFailed(let message):
                return message
            }
        }
    }
}
