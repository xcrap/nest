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

        return (passed, failed)
    }
}
