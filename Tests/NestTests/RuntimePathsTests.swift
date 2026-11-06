import Foundation
import NestLib

enum RuntimePathsTests {
    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0

        func assert(_ condition: Bool, _ msg: String, file: String = #file, line: Int = #line) {
            if condition {
                passed += 1
            } else {
                failed += 1
                print("  FAIL: \(msg) (\(file):\(line))")
            }
        }

        // Test: fillingMissingValues keeps explicit custom values.
        do {
            let current = RuntimePaths(
                frankenphpBinary: "/custom/frankenphp",
                cloudflaredBinary: "",
                frankenphpLog: "/tmp/frankenphp.log"
            )
            let defaults = RuntimePaths(
                frankenphpBinary: "/opt/homebrew/bin/frankenphp",
                cloudflaredBinary: "/opt/homebrew/bin/cloudflared",
                frankenphpLog: "/opt/homebrew/var/log/frankenphp.log"
            )

            let merged = current.fillingMissingValues(from: defaults)
            assert(merged.frankenphpBinary == "/custom/frankenphp", "should keep custom frankenphp binary")
            assert(merged.cloudflaredBinary == "/opt/homebrew/bin/cloudflared", "should fill missing cloudflared binary")
            assert(merged.frankenphpLog == "/tmp/frankenphp.log", "should keep custom frankenphp log")
        }

        // Test: fillingMissingValues leaves complete values unchanged.
        do {
            let current = RuntimePaths(
                frankenphpBinary: "/opt/homebrew/bin/frankenphp",
                mariadbServer: "/opt/homebrew/bin/mariadbd",
                mariadbClient: "/opt/homebrew/bin/mariadb",
                mysqldump: "/opt/homebrew/bin/mariadb-dump",
                cloudflaredBinary: "/opt/homebrew/bin/cloudflared",
                frankenphpLog: "/opt/homebrew/var/log/frankenphp.log",
                mariadbLog: "/opt/homebrew/var/mysql/mini.err",
                cloudflaredLog: "/opt/homebrew/var/log/cloudflared.log",
                phpIniPath: "/opt/homebrew/etc/php.ini"
            )

            let merged = current.fillingMissingValues(from: RuntimePaths())
            assert(merged == current, "complete runtime paths should remain unchanged")
        }

        // Test: targeted detection only looks for empty fields, and launches FrankenPHP for
        // php.ini only when optional detection is wanted.
        do {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nest-runtime-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let marker = directory.appendingPathComponent("runs")
            let ini = directory.appendingPathComponent("php.ini")
            try "; fixture".write(to: ini, atomically: true, encoding: .utf8)
            let frankenphp = directory.appendingPathComponent("frankenphp")
            try "#!/bin/sh\necho run >> '\(marker.path)'\necho\necho '\(ini.path)'\n".write(to: frankenphp, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: frankenphp.path)
            let ran = { FileManager.default.fileExists(atPath: marker.path) }

            var current = RuntimePaths(frankenphpBinary: frankenphp.path, mariadbServer: "", mariadbClient: "/x/mariadb",
                                       mysqldump: "/x/dump", cloudflaredBinary: "/x/cloudflared", frankenphpLog: "/x/f.log",
                                       mariadbLog: "/x/m.err", cloudflaredLog: "/x/c.log", phpIniPath: "")
            let requiredOnly = RuntimePaths.detectDefaults(missingFrom: current, includingOptional: false)
            assert(requiredOnly == RuntimePaths(), "required-only detection leaves optional fields alone")
            assert(!ran(), "required-only detection does not launch a configured FrankenPHP")

            let withOptional = RuntimePaths.detectDefaults(missingFrom: current, includingOptional: true)
            assert(ran() && withOptional.phpIniPath == ini.path, "optional detection finds php.ini through the configured FrankenPHP")
            assert(withOptional.frankenphpBinary.isEmpty && withOptional.mariadbClient.isEmpty, "detection never proposes values for fields already set")

            try FileManager.default.removeItem(at: marker)
            current.phpIniPath = ini.path
            current.mariadbServer = "/x/mariadbd"
            assert(RuntimePaths.detectDefaults(missingFrom: current, includingOptional: true) == RuntimePaths(), "complete paths detect nothing")
            assert(!ran(), "complete paths never launch FrankenPHP")
        } catch {
            failed += 1
            print("  FAIL: targeted detection threw: \(error)")
        }

        return (passed, failed)
    }
}
