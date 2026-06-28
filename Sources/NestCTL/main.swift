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

        let store = SiteStore()

        do {
            switch command {
            case "start":
                try start(arguments.dropFirst().first ?? "all", store: store)
            case "stop":
                stop(arguments.dropFirst().first ?? "all")
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
    private static func start(_ target: String, store: SiteStore) throws {
        switch target {
        case "frankenphp":
            try writeCaddyConfig(store: store)
            try runBrew(.start, service: "frankenphp")
        case "mariadb":
            try runBrew(.start, service: "mariadb")
        case "cloudflared":
            try writeCloudflaredConfig(store: store)
            try startCloudflared(store: store)
        case "all":
            try start("frankenphp", store: store)
            try start("mariadb", store: store)
            try start("cloudflared", store: store)
        default:
            throw CLIError.invalidTarget(target)
        }
    }

    @MainActor
    private static func stop(_ target: String) {
        switch target {
        case "frankenphp":
            _ = SystemProcess.capture(BrewServiceController.brewPath, arguments: ["services", "stop", "frankenphp"])
            _ = SystemProcess.capture("/usr/bin/killall", arguments: ["frankenphp"])
        case "mariadb":
            _ = SystemProcess.capture(BrewServiceController.brewPath, arguments: ["services", "stop", "mariadb"])
            _ = SystemProcess.capture("/usr/bin/killall", arguments: ["mariadbd"])
        case "cloudflared":
            _ = LaunchAgentService.stop(label: ProcessController.cloudflaredLaunchAgentLabel)
            _ = SystemProcess.capture("/usr/bin/pkill", arguments: ["-f", "cloudflared.*tunnel.*run"])
        case "all":
            stop("cloudflared")
            stop("frankenphp")
            stop("mariadb")
        default:
            print("Unknown target: \(target)")
        }
    }

    @MainActor
    private static func reload(store: SiteStore) async throws {
        let renderer = try writeCaddyConfig(store: store)
        let caddyfile = try String(contentsOfFile: renderer.caddyfilePath, encoding: .utf8)
        var request = URLRequest(url: URL(string: "http://localhost:2019/load")!)
        request.httpMethod = "POST"
        request.setValue("text/caddyfile", forHTTPHeaderField: "Content-Type")
        request.httpBody = caddyfile.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CLIError.requestFailed("Caddy reload failed: \(body)")
        }
        print("Reloaded FrankenPHP/Caddy config.")
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
        try writeCloudflaredConfig(store: store)
        try await CloudflareService.pushTunnelConfiguration(
            settings: store.settings.cloudflareSettings,
            routes: store.tunnelRoutes,
            sites: store.sites,
            projects: store.appProjects
        )
        print("Pushed tunnel configuration to Cloudflare.")
    }

    @MainActor
    @discardableResult
    private static func writeCaddyConfig(store: SiteStore) throws -> ConfigRenderer {
        let renderer = caddyRenderer(store: store)
        try renderer.writeAll(sites: store.sites)
        print("Wrote \(renderer.caddyfilePath)")
        return renderer
    }

    @MainActor
    private static func writeCloudflaredConfig(store: SiteStore) throws {
        let renderer = tunnelRenderer(store: store)
        try renderer.writeConfig(routes: store.tunnelRoutes, sites: store.sites, projects: store.appProjects)
        print("Wrote \(store.settings.cloudflareSettings.configPath)")
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

    @MainActor
    private static func startCloudflared(store: SiteStore) throws {
        let settings = store.settings
        guard FileManager.default.isExecutableFile(atPath: settings.runtimePaths.cloudflaredBinary) else {
            throw CLIError.requestFailed("cloudflared binary is not executable at \(settings.runtimePaths.cloudflaredBinary).")
        }
        guard settings.cloudflareSettings.hasLocalConfiguration else {
            throw CloudflareServiceError.missingLocalConfiguration
        }

        let definition = LaunchAgentDefinition(
            label: ProcessController.cloudflaredLaunchAgentLabel,
            programArguments: [
                settings.runtimePaths.cloudflaredBinary,
                "--config",
                settings.cloudflareSettings.configPath,
                "tunnel",
                "run",
                settings.cloudflareSettings.tunnelName
            ],
            standardOutPath: settings.runtimePaths.cloudflaredLog,
            standardErrorPath: settings.runtimePaths.cloudflaredLog
        )
        let result = LaunchAgentService.start(definition)
        guard result.status == 0 else {
            throw CLIError.requestFailed(result.output.isEmpty ? "Failed to start cloudflared." : result.output)
        }
        print("Started cloudflared.")
    }

    private static func runBrew(_ action: BrewServiceAction, service: String) throws {
        guard FileManager.default.isExecutableFile(atPath: BrewServiceController.brewPath) else {
            throw CLIError.requestFailed("Homebrew is not available at \(BrewServiceController.brewPath).")
        }
        let result = SystemProcess.capture(
            BrewServiceController.brewPath,
            arguments: ["services", action.rawValue, service]
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
