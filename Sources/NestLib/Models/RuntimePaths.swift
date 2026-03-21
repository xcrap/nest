import Foundation

public struct RuntimePaths: Codable, Equatable {
    public var frankenphpBinary: String
    public var mariadbServer: String
    public var mariadbClient: String
    public var mysqldump: String
    public var frankenphpLog: String
    public var mariadbLog: String

    public init(
        frankenphpBinary: String = "",
        mariadbServer: String = "",
        mariadbClient: String = "",
        mysqldump: String = "",
        frankenphpLog: String = "",
        mariadbLog: String = ""
    ) {
        self.frankenphpBinary = frankenphpBinary
        self.mariadbServer = mariadbServer
        self.mariadbClient = mariadbClient
        self.mysqldump = mysqldump
        self.frankenphpLog = frankenphpLog
        self.mariadbLog = mariadbLog
    }

    /// Try to detect default Homebrew paths.
    public static func detectDefaults() -> RuntimePaths {
        let brewPrefix = "/opt/homebrew"
        let fm = FileManager.default

        var paths = RuntimePaths()

        // FrankenPHP: Homebrew first, then legacy Nest-managed binary
        let frankenphpCandidates = [
            "\(brewPrefix)/bin/frankenphp",
            NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)
                .first.map { ($0 as NSString).appendingPathComponent("Nest/bin/frankenphp") } ?? "",
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

        // MariaDB log: prefer Homebrew default
        let brewDBLog = "\(brewPrefix)/var/mysql/\(Host.current().localizedName ?? "localhost").err"
        if fm.fileExists(atPath: brewDBLog) {
            paths.mariadbLog = brewDBLog
        } else {
            paths.mariadbLog = brewDBLog
        }

        return paths
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

        return issues
    }
}
