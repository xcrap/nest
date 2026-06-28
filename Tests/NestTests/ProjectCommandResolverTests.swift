import Foundation
import NestLib

enum ProjectCommandResolverTests {
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

        // Test: parses simple commands without involving a shell.
        do {
            let spec = ProjectCommandResolver.resolve(
                command: "NODE_ENV=production bun run start --host 0.0.0.0",
                directory: "/tmp/missing",
                port: 3999
            )
            assert(spec.programArguments == ["/usr/bin/env", "bun", "run", "start", "--host", "0.0.0.0"], "should parse direct command arguments")
            assert(spec.environmentOverrides["NODE_ENV"] == "production", "should parse environment assignments")
        }

        // Test: falls back to shell when command uses shell-only operators.
        do {
            let command = "bun run build && bun run start"
            let spec = ProjectCommandResolver.resolve(command: command, directory: "/tmp/missing", port: 3999)
            assert(spec.programArguments == ["/bin/zsh", "-c", command], "should preserve shell commands")
            assert(spec.environmentOverrides.isEmpty, "shell fallback should not parse env overrides")
        }

        // Test: detects common JS frameworks from package.json.
        do {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let package = #"{"dependencies":{"vite":"latest"},"scripts":{"dev":"vite"}}"#
            try Data(package.utf8).write(to: directory.appendingPathComponent("package.json"))

            let spec = ProjectCommandResolver.resolve(command: "", directory: directory.path, port: 5173)
            assert(spec.programArguments == ["/usr/bin/env", "bun", "x", "vite", "--host", "--port", "5173"], "should detect vite projects")
        } catch {
            failed += 1
            print("  FAIL: package detection test threw: \(error)")
        }

        return (passed, failed)
    }

    private static func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nest-command-\(UUID().uuidString)", isDirectory: true)
    }
}
