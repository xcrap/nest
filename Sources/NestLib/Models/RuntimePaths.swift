import Foundation

public struct RuntimePaths: Codable, Equatable, Sendable {
    public var frankenphpBinary: String
    public var mariadbServer: String
    public var mariadbClient: String
    public var mysqldump: String
    public var cloudflaredBinary: String
    public var frankenphpLog: String
    public var mariadbLog: String
    public var cloudflaredLog: String
    public var phpIniPath: String

    public init(
        frankenphpBinary: String = "",
        mariadbServer: String = "",
        mariadbClient: String = "",
        mysqldump: String = "",
        cloudflaredBinary: String = "",
        frankenphpLog: String = "",
        mariadbLog: String = "",
        cloudflaredLog: String = "",
        phpIniPath: String = ""
    ) {
        self.frankenphpBinary = frankenphpBinary
        self.mariadbServer = mariadbServer
        self.mariadbClient = mariadbClient
        self.mysqldump = mysqldump
        self.cloudflaredBinary = cloudflaredBinary
        self.frankenphpLog = frankenphpLog
        self.mariadbLog = mariadbLog
        self.cloudflaredLog = cloudflaredLog
        self.phpIniPath = phpIniPath
    }

    enum CodingKeys: String, CodingKey {
        case frankenphpBinary
        case mariadbServer
        case mariadbClient
        case mysqldump
        case cloudflaredBinary
        case frankenphpLog
        case mariadbLog
        case cloudflaredLog
        case phpIniPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frankenphpBinary = try container.decodeIfPresent(String.self, forKey: .frankenphpBinary) ?? ""
        mariadbServer = try container.decodeIfPresent(String.self, forKey: .mariadbServer) ?? ""
        mariadbClient = try container.decodeIfPresent(String.self, forKey: .mariadbClient) ?? ""
        mysqldump = try container.decodeIfPresent(String.self, forKey: .mysqldump) ?? ""
        cloudflaredBinary = try container.decodeIfPresent(String.self, forKey: .cloudflaredBinary) ?? ""
        frankenphpLog = try container.decodeIfPresent(String.self, forKey: .frankenphpLog) ?? ""
        mariadbLog = try container.decodeIfPresent(String.self, forKey: .mariadbLog) ?? ""
        cloudflaredLog = try container.decodeIfPresent(String.self, forKey: .cloudflaredLog) ?? ""
        phpIniPath = try container.decodeIfPresent(String.self, forKey: .phpIniPath) ?? ""
    }

    /// Try to detect default Homebrew paths.
    public static func detectDefaults() -> RuntimePaths {
        detectDefaults(missingFrom: RuntimePaths(), includingOptional: true)
    }

    /// Detects only the fields that are empty in `current`; every other field is left empty.
    /// The required FrankenPHP binary is always detected (a file check). Optional binaries, logs
    /// and php.ini are detected only when `includingOptional` is true, except that php.ini
    /// detection (which launches FrankenPHP) also runs when FrankenPHP was just found.
    public static func detectDefaults(missingFrom current: RuntimePaths, includingOptional: Bool) -> RuntimePaths {
        let brewPrefix = "/opt/homebrew"
        let fm = FileManager.default
        func firstExecutable(_ candidates: [String]) -> String {
            candidates.first { fm.isExecutableFile(atPath: $0) } ?? ""
        }

        var paths = RuntimePaths()

        // FrankenPHP: Homebrew first, then legacy Nest-managed binary
        if current.frankenphpBinary.isEmpty {
            paths.frankenphpBinary = firstExecutable([
                "\(brewPrefix)/bin/frankenphp",
                (AppSettings.nestBinDirectory as NSString).appendingPathComponent("frankenphp"),
            ])
        }

        if includingOptional {
            if current.mariadbServer.isEmpty {
                paths.mariadbServer = firstExecutable(["\(brewPrefix)/bin/mariadbd", "\(brewPrefix)/bin/mysqld"])
            }
            if current.mariadbClient.isEmpty {
                paths.mariadbClient = firstExecutable(["\(brewPrefix)/bin/mariadb", "\(brewPrefix)/bin/mysql"])
            }
            if current.mysqldump.isEmpty {
                paths.mysqldump = firstExecutable(["\(brewPrefix)/bin/mariadb-dump", "\(brewPrefix)/bin/mysqldump"])
            }
            if current.cloudflaredBinary.isEmpty {
                paths.cloudflaredBinary = firstExecutable(["\(brewPrefix)/bin/cloudflared"])
            }

            // FrankenPHP log: prefer Homebrew default, then Caddy default
            if current.frankenphpLog.isEmpty {
                let brewFPLog = "\(brewPrefix)/var/log/frankenphp.log"
                let caddyLog = "\(NSHomeDirectory())/.local/share/caddy/logs/default.log"
                paths.frankenphpLog = !fm.fileExists(atPath: brewFPLog) && fm.fileExists(atPath: caddyLog) ? caddyLog : brewFPLog
            }
            if current.mariadbLog.isEmpty {
                paths.mariadbLog = "\(brewPrefix)/var/mysql/\(Host.current().localizedName ?? "localhost").err"
            }
            if current.cloudflaredLog.isEmpty {
                paths.cloudflaredLog = defaultCloudflaredLog
            }
        }

        // PHP ini: detect from FrankenPHP binary. A stalled PHP startup must not hang the caller.
        let frankenphp = current.frankenphpBinary.isEmpty ? paths.frankenphpBinary : current.frankenphpBinary
        let foundFrankenPHP = current.frankenphpBinary.isEmpty && !paths.frankenphpBinary.isEmpty
        if current.phpIniPath.isEmpty, includingOptional || foundFrankenPHP,
           !frankenphp.isEmpty, fm.isExecutableFile(atPath: frankenphp) {
            paths.phpIniPath = detectPHPIniPath(frankenphpBinary: frankenphp)
        }

        return paths
    }

    public static var defaultCloudflaredLog: String {
        (AppSettings.nestLogsDirectory as NSString).appendingPathComponent("cloudflared.log")
    }

    private static func detectPHPIniPath(frankenphpBinary: String) -> String {
        let result = SystemProcess.capture(
            frankenphpBinary,
            arguments: ["php-cli", "-r", "echo PHP_EOL, php_ini_loaded_file();"],
            timeout: 5
        )
        guard result.status == 0 else { return "" }
        // Startup warnings share the output file; the loaded ini path is always the last line.
        let candidate = result.output
            .split(whereSeparator: \.isNewline)
            .last
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard candidate.hasPrefix("/"), FileManager.default.fileExists(atPath: candidate) else { return "" }
        return candidate
    }

    public var hasMissingValues: Bool {
        [frankenphpBinary, mariadbServer, mariadbClient, mysqldump, cloudflaredBinary,
         frankenphpLog, mariadbLog, cloudflaredLog, phpIniPath].contains(where: \.isEmpty)
    }

    public func fillingMissingValues(from defaults: @autoclosure () -> RuntimePaths = RuntimePaths.detectDefaults()) -> RuntimePaths {
        guard hasMissingValues else { return self }
        let defaults = defaults()
        var merged = self

        if merged.frankenphpBinary.isEmpty {
            merged.frankenphpBinary = defaults.frankenphpBinary
        }
        if merged.mariadbServer.isEmpty {
            merged.mariadbServer = defaults.mariadbServer
        }
        if merged.mariadbClient.isEmpty {
            merged.mariadbClient = defaults.mariadbClient
        }
        if merged.mysqldump.isEmpty {
            merged.mysqldump = defaults.mysqldump
        }
        if merged.cloudflaredBinary.isEmpty {
            merged.cloudflaredBinary = defaults.cloudflaredBinary
        }
        if merged.frankenphpLog.isEmpty {
            merged.frankenphpLog = defaults.frankenphpLog
        }
        if merged.mariadbLog.isEmpty {
            merged.mariadbLog = defaults.mariadbLog
        }
        if merged.cloudflaredLog.isEmpty {
            merged.cloudflaredLog = defaults.cloudflaredLog
        }
        if merged.phpIniPath.isEmpty {
            merged.phpIniPath = defaults.phpIniPath
        }

        return merged
    }

    /// Blocking problems: FrankenPHP is required, and any path that is set must point at an executable.
    public func validate() -> [String] {
        var issues: [String] = []
        let fm = FileManager.default

        if frankenphpBinary.isEmpty {
            issues.append("FrankenPHP binary path is not set.")
        }

        for (label, path) in binaries where !path.isEmpty && !fm.isExecutableFile(atPath: path) {
            issues.append("\(label) not found or not executable at: \(path)")
        }

        return issues
    }

    /// Optional binaries that are simply not configured; the related features stay unavailable.
    public func optionalIssues() -> [String] {
        binaries.dropFirst()
            .filter { $0.path.isEmpty }
            .map { "\($0.label) path is not set (optional)." }
    }

    private var binaries: [(label: String, path: String)] {
        [
            ("FrankenPHP binary", frankenphpBinary),
            ("MariaDB server", mariadbServer),
            ("MariaDB client", mariadbClient),
            ("mysqldump", mysqldump),
            ("cloudflared binary", cloudflaredBinary)
        ]
    }
}
