import Foundation

public struct RuntimePaths: Codable, Equatable {
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

        // PHP ini: detect from FrankenPHP binary
        if !paths.frankenphpBinary.isEmpty {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: paths.frankenphpBinary)
            process.arguments = ["php-cli", "-r", "echo php_ini_loaded_file();"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let detectedPath = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !detectedPath.isEmpty {
                paths.phpIniPath = detectedPath
            }
        }

        // MariaDB log: prefer Homebrew default
        let brewDBLog = "\(brewPrefix)/var/mysql/\(Host.current().localizedName ?? "localhost").err"
        if fm.fileExists(atPath: brewDBLog) {
            paths.mariadbLog = brewDBLog
        } else {
            paths.mariadbLog = brewDBLog
        }

        paths.cloudflaredLog = (AppSettings.nestLogsDirectory as NSString)
            .appendingPathComponent("cloudflared.log")

        return paths
    }

    public func fillingMissingValues(from defaults: RuntimePaths = RuntimePaths.detectDefaults()) -> RuntimePaths {
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

    public func validate() -> [String] {
        var issues: [String] = []
        let fm = FileManager.default

        if frankenphpBinary.isEmpty {
            issues.append("FrankenPHP binary path is not set.")
        } else if !fm.isExecutableFile(atPath: frankenphpBinary) {
            issues.append("FrankenPHP binary not found or not executable at: \(frankenphpBinary)")
        }

        if mariadbServer.isEmpty {
            issues.append("MariaDB server path is not set.")
        } else if !fm.isExecutableFile(atPath: mariadbServer) {
            issues.append("MariaDB server not found or not executable at: \(mariadbServer)")
        }

        if mariadbClient.isEmpty {
            issues.append("MariaDB client path is not set.")
        } else if !fm.isExecutableFile(atPath: mariadbClient) {
            issues.append("MariaDB client not found or not executable at: \(mariadbClient)")
        }

        if mysqldump.isEmpty {
            issues.append("mysqldump path is not set.")
        } else if !fm.isExecutableFile(atPath: mysqldump) {
            issues.append("mysqldump not found or not executable at: \(mysqldump)")
        }

        if cloudflaredBinary.isEmpty {
            issues.append("cloudflared binary path is not set.")
        } else if !fm.isExecutableFile(atPath: cloudflaredBinary) {
            issues.append("cloudflared binary not found or not executable at: \(cloudflaredBinary)")
        }

        return issues
    }
}
