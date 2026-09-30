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
        let brewPrefix = "/opt/homebrew"
        let fm = FileManager.default

        var paths = RuntimePaths()

        // FrankenPHP: Homebrew first, then legacy Nest-managed binary
        let frankenphpCandidates = [
            "\(brewPrefix)/bin/frankenphp",
            (AppSettings.nestBinDirectory as NSString).appendingPathComponent("frankenphp"),
        ]
        for candidate in frankenphpCandidates {
            if !candidate.isEmpty && fm.isExecutableFile(atPath: candidate) {
                paths.frankenphpBinary = candidate
                break
            }
        }

        let mariadbd = "\(brewPrefix)/bin/mariadbd"
        if fm.isExecutableFile(atPath: mariadbd) {
            paths.mariadbServer = mariadbd
        } else {
            let mysqld = "\(brewPrefix)/bin/mysqld"
            if fm.isExecutableFile(atPath: mysqld) {
                paths.mariadbServer = mysqld
            }
        }

        let mariadb = "\(brewPrefix)/bin/mariadb"
        if fm.isExecutableFile(atPath: mariadb) {
            paths.mariadbClient = mariadb
        } else {
            let mysql = "\(brewPrefix)/bin/mysql"
            if fm.isExecutableFile(atPath: mysql) {
                paths.mariadbClient = mysql
            }
        }

        let dump = "\(brewPrefix)/bin/mariadb-dump"
        if fm.isExecutableFile(atPath: dump) {
            paths.mysqldump = dump
        } else {
            let mysqldumpBin = "\(brewPrefix)/bin/mysqldump"
            if fm.isExecutableFile(atPath: mysqldumpBin) {
                paths.mysqldump = mysqldumpBin
            }
        }

        let cloudflared = "\(brewPrefix)/bin/cloudflared"
        if fm.isExecutableFile(atPath: cloudflared) {
            paths.cloudflaredBinary = cloudflared
        }

        // FrankenPHP log: prefer Homebrew default, then Caddy default
        let brewFPLog = "\(brewPrefix)/var/log/frankenphp.log"
        let homeDir = NSHomeDirectory()
        let caddyLog = "\(homeDir)/.local/share/caddy/logs/default.log"
        if fm.fileExists(atPath: brewFPLog) {
            paths.frankenphpLog = brewFPLog
        } else if fm.fileExists(atPath: caddyLog) {
            paths.frankenphpLog = caddyLog
        } else {
            paths.frankenphpLog = brewFPLog
        }

        // PHP ini: detect from FrankenPHP binary. A stalled PHP startup must not hang the caller.
        if !paths.frankenphpBinary.isEmpty {
            paths.phpIniPath = detectPHPIniPath(frankenphpBinary: paths.frankenphpBinary)
        }

        paths.mariadbLog = "\(brewPrefix)/var/mysql/\(Host.current().localizedName ?? "localhost").err"
        paths.cloudflaredLog = defaultCloudflaredLog

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
