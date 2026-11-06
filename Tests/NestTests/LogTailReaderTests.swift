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

        // Test: clearing keeps the same file, so a service appending to it stays visible.
        do {
            let path = (tempDir as NSString).appendingPathComponent("live.log")
            try? "old line\n".write(toFile: path, atomically: true, encoding: .utf8)
            let writer = FileHandle(forWritingAtPath: path)
            _ = try? writer?.seekToEnd()
            let inodeBefore = (try? FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber]) as? Int

            try? LogTailReader.truncate(path: path)
            try? writer?.write(contentsOf: Data("new line\n".utf8))
            try? writer?.close()

            let inodeAfter = (try? FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber]) as? Int
            assert(inodeBefore != nil && inodeBefore == inodeAfter, "truncate should keep the same file")
            assert(LogTailReader.read(path: path).contains("new line"), "writes after clearing should be visible")
            assert(!LogTailReader.read(path: path).contains("old line"), "clearing should remove old content")
        }

        func append(_ text: String, to path: String) {
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
            try? handle.close()
        }

        func appendBytes(_ bytes: [UInt8], to path: String) {
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(bytes))
            try? handle.close()
        }

        // Test: missing, unreadable and empty files are told apart.
        do {
            let missing = LogTailReader.poll(path: (tempDir as NSString).appendingPathComponent("nope.log"), state: nil)
            assert(missing.result == .missing && missing.state == nil, "missing file reports .missing")

            let folder = LogTailReader.poll(path: tempDir, state: nil)
            if case .unreadable = folder.result { assert(true, "") } else { assert(false, "folder reports .unreadable") }

            let empty = (tempDir as NSString).appendingPathComponent("empty.log")
            FileManager.default.createFile(atPath: empty, contents: Data())
            let emptyRead = LogTailReader.poll(path: empty, state: nil)
            assert(emptyRead.result == .replaced("") && emptyRead.state != nil, "empty file reports empty content")

            let locked = (tempDir as NSString).appendingPathComponent("locked.log")
            FileManager.default.createFile(atPath: locked, contents: Data("secret\n".utf8))
            chmod(locked, 0o000)
            if getuid() != 0 {
                let lockedRead = LogTailReader.poll(path: locked, state: nil)
                if case .unreadable(let message) = lockedRead.result {
                    assert(message.contains("Permission"), "permission error explains itself")
                } else {
                    assert(false, "unreadable file reports .unreadable, not empty")
                }
            }
            chmod(locked, 0o644)
        }

        // Test: only new bytes are returned after the first read.
        do {
            let path = (tempDir as NSString).appendingPathComponent("incremental.log")
            try? "one\ntwo\n".write(toFile: path, atomically: false, encoding: .utf8)
            let first = LogTailReader.poll(path: path, state: nil)
            assert(first.result == .replaced("one\ntwo"), "first read replaces with the window, holding the trailing newline")

            let idle = LogTailReader.poll(path: path, state: first.state)
            assert(idle.result == .unchanged, "no new bytes reports unchanged")

            append("three\n", to: path)
            let second = LogTailReader.poll(path: path, state: idle.state)
            assert(second.result == .appended("\nthree"), "appended text includes the held newline")
            assert(second.state?.offset == 14, "offset advances to the end of the file")

            append("partial", to: path)
            let third = LogTailReader.poll(path: path, state: second.state)
            assert(third.result == .appended("\npartial"), "a line without newline is shown")
            append(" line\n", to: path)
            let fourth = LogTailReader.poll(path: path, state: third.state)
            assert(fourth.result == .appended(" line"), "the rest of a line continues it")
        }

        // Test: a UTF-8 character split across reads is decoded once it is complete.
        do {
            let path = (tempDir as NSString).appendingPathComponent("utf8.log")
            try? "start\n".write(toFile: path, atomically: false, encoding: .utf8)
            let first = LogTailReader.poll(path: path, state: nil)
            appendBytes([0x63, 0x61, 0x66, 0xC3], to: path) // "caf" + first byte of "é"
            let split = LogTailReader.poll(path: path, state: first.state)
            assert(split.result == .appended("\ncaf"), "incomplete character is held back")
            appendBytes([0xA9, 0x0A], to: path)
            let joined = LogTailReader.poll(path: path, state: split.state)
            assert(joined.result == .appended("é"), "completed character is decoded intact")
        }

        // Test: truncation starts over.
        do {
            let path = (tempDir as NSString).appendingPathComponent("truncate.log")
            try? "aaaa\nbbbb\ncccc\n".write(toFile: path, atomically: false, encoding: .utf8)
            let first = LogTailReader.poll(path: path, state: nil)
            try? LogTailReader.truncate(path: path)
            append("new\n", to: path)
            let after = LogTailReader.poll(path: path, state: first.state)
            assert(after.result == .replaced("new"), "shorter file replaces the content")
        }

        // Test: truncate-and-regrow past the old offset is still detected.
        do {
            let path = (tempDir as NSString).appendingPathComponent("regrow.log")
            try? "old-1\nold-2\n".write(toFile: path, atomically: false, encoding: .utf8)
            let first = LogTailReader.poll(path: path, state: nil)
            try? LogTailReader.truncate(path: path)
            append("fresh-1\nfresh-2\nfresh-3\n", to: path)
            let after = LogTailReader.poll(path: path, state: first.state)
            assert(after.result == .replaced("fresh-1\nfresh-2\nfresh-3"), "rewritten file replaces the content")
        }

        // Test: rotation (a new file at the same path) starts over.
        do {
            let path = (tempDir as NSString).appendingPathComponent("rotate.log")
            try? "before\n".write(toFile: path, atomically: false, encoding: .utf8)
            let first = LogTailReader.poll(path: path, state: nil)
            try? FileManager.default.moveItem(atPath: path, toPath: path + ".1")
            try? "after rotation, a longer first line\n".write(toFile: path, atomically: false, encoding: .utf8)
            let after = LogTailReader.poll(path: path, state: first.state)
            assert(after.result == .replaced("after rotation, a longer first line"), "new inode replaces the content")
        }

        // Test: more new data than the window replaces with the newest window.
        do {
            let path = (tempDir as NSString).appendingPathComponent("burst.log")
            try? "seed\n".write(toFile: path, atomically: false, encoding: .utf8)
            let first = LogTailReader.poll(path: path, state: nil, maxBytes: 64)
            append((1...50).map { "burst-\($0)\n" }.joined(), to: path)
            let after = LogTailReader.poll(path: path, state: first.state, maxBytes: 64)
            if case .replaced(let text) = after.result {
                assert(text.hasSuffix("burst-50") && !text.contains("seed"), "burst keeps only the newest window")
            } else {
                assert(false, "burst larger than the window replaces the content")
            }
        }

        // Test: the line cap applies to the first read, ignoring the trailing newline.
        do {
            let path = (tempDir as NSString).appendingPathComponent("cap.log")
            try? "l1\nl2\nl3\nl4\n".write(toFile: path, atomically: false, encoding: .utf8)
            let read = LogTailReader.poll(path: path, state: nil, maxLines: 2)
            assert(read.result == .replaced("l3\nl4"), "line cap keeps the newest lines")
        }

        // Test: the display window trims whole lines from the top.
        do {
            let text = "a\nb\nc\nd" as NSString
            assert(LogTailReader.overflowPrefixLength(of: text, maxLines: 10, maxLength: 100) == 0, "within limits nothing is trimmed")
            assert(LogTailReader.overflowPrefixLength(of: text, maxLines: 2, maxLength: 100) == 4, "line cap trims to the newest lines")
            let long = "aaaa\nbbbb\ncccc" as NSString
            assert(LogTailReader.overflowPrefixLength(of: long, maxLines: 10, maxLength: 6) == 10, "length cap cuts at a line boundary")
            assert(LogTailReader.overflowPrefixLength(of: long, maxLines: 10, maxLength: 4) == 10, "cut exactly at a line start")
            assert(LogTailReader.overflowPrefixLength(of: "" as NSString, maxLines: 1, maxLength: 1) == 0, "empty text needs no trim")
        }

        return (passed, failed)
    }
}
