import Foundation
import NestLib

enum LogTailReaderTests {
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

        let tempDir = NSTemporaryDirectory() + "nest-log-tests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        // Test: empty path returns empty content.
        do {
            let content = LogTailReader.read(path: "")
            assert(content.isEmpty, "empty path should return empty content")
        }

        // Test: missing file returns empty content.
        do {
            let content = LogTailReader.read(path: (tempDir as NSString).appendingPathComponent("missing.log"))
            assert(content.isEmpty, "missing file should return empty content")
        }

        // Test: tail read drops partial first line when reading from the middle of a file.
        do {
            let path = (tempDir as NSString).appendingPathComponent("partial.log")
            let source = "first\nsecond\nthird\n"
            try? source.write(toFile: path, atomically: true, encoding: .utf8)

            let content = LogTailReader.read(path: path, maxBytes: 10, maxLines: 10)
            assert(content == "third", "tail should trim the partial first line")
        }

        // Test: line cap keeps only the newest lines.
        do {
            let path = (tempDir as NSString).appendingPathComponent("lines.log")
            let source = (1...6).map { "line-\($0)" }.joined(separator: "\n")
            try? source.write(toFile: path, atomically: true, encoding: .utf8)

            let content = LogTailReader.read(path: path, maxBytes: 4_096, maxLines: 2)
            assert(content == "line-5\nline-6", "line cap should keep only the newest lines")
        }

        // Test: byte cap still returns recent content for larger files.
        do {
            let path = (tempDir as NSString).appendingPathComponent("recent.log")
            let source = (1...200).map { "entry-\($0)" }.joined(separator: "\n")
            try? source.write(toFile: path, atomically: true, encoding: .utf8)

            let content = LogTailReader.read(path: path, maxBytes: 64, maxLines: 20)
            assert(content.contains("entry-200"), "byte cap should include the newest entries")
            assert(!content.contains("entry-1\n"), "byte cap should exclude old entries")
        }

        return (passed, failed)
    }
}
