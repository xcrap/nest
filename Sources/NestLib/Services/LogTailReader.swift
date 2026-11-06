import Foundation

/// Where an incremental log read left off. Opaque to callers: pass the value returned by
/// `LogTailReader.poll` back into the next call.
public struct LogTailState: Equatable, Sendable {
    /// Bytes of the file already shown.
    public fileprivate(set) var offset: UInt64
    fileprivate var device: Int32
    fileprivate var inode: UInt64
    /// The last bytes before `offset`; if they change, the file was truncated and rewritten
    /// (copytruncate rotation, or "Clear" followed by new writes) since the last read.
    fileprivate var signature: Data
    /// A trailing newline that has been read but not yet shown, so the view does not end
    /// with an empty line.
    fileprivate var heldNewline: Bool
}

public enum LogTailResult: Equatable, Sendable {
    /// No file exists at the path (yet).
    case missing
    /// The file exists but cannot be read; the message says why.
    case unreadable(String)
    /// Replace everything shown with this text (first read, truncation or rotation).
    case replaced(String)
    /// Append this text to what is already shown.
    case appended(String)
    /// Nothing new since the last read.
    case unchanged
}

public enum LogTailReader {
    public static let defaultMaxBytes = 128_000
    public static let defaultMaxLines = 2_000
    private static let signatureLength = 64

    // MARK: - Incremental reading

    /// Reads only what was written since `state`. A nil state, a different file (rotation),
    /// a shorter file (truncation) or more than `maxBytes` of new data start over with the
    /// newest window of the file.
    public static func poll(
        path: String,
        state: LogTailState?,
        maxBytes: Int = defaultMaxBytes,
        maxLines: Int = defaultMaxLines
    ) -> (result: LogTailResult, state: LogTailState?) {
        guard !path.isEmpty else { return (.missing, nil) }
        guard maxBytes > 0, maxLines > 0 else { return (.replaced(""), nil) }

        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return (.missing, nil) }
            return (.unreadable(message(forErrno: code)), nil)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { try? handle.close() }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return (.unreadable(message(forErrno: errno)), nil) }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
            return (.unreadable(isDirectory ? "This path is a folder, not a log file." : "This path is not a regular file."), nil)
        }
        let size = UInt64(max(info.st_size, 0))
        let inode = UInt64(info.st_ino)
        let device = Int32(info.st_dev)

        do {
            if let state, state.inode == inode, state.device == device, size >= state.offset,
               size - state.offset <= UInt64(maxBytes) {
                if let appended = try readAppended(handle: handle, state: state, size: size) {
                    return appended
                }
            }
            return try readWindow(handle: handle, size: size, device: device, inode: inode, maxBytes: maxBytes, maxLines: maxLines)
        } catch {
            return (.unreadable(error.localizedDescription), nil)
        }
    }

    /// Returns nil when the bytes before the saved offset no longer match (the file was
    /// rewritten), so the caller starts over.
    private static func readAppended(
        handle: FileHandle,
        state: LogTailState,
        size: UInt64
    ) throws -> (result: LogTailResult, state: LogTailState?)? {
        let signatureCount = UInt64(state.signature.count)
        guard state.offset >= signatureCount else { return nil }
        try handle.seek(toOffset: state.offset - signatureCount)
        let data = try handle.read(upToCount: Int(signatureCount + (size - state.offset))) ?? Data()
        guard data.count >= state.signature.count,
              data.prefix(state.signature.count) == state.signature else { return nil }

        let fresh = data.dropFirst(state.signature.count)
        let consumed = completeUTF8Length(fresh)
        guard consumed > 0 else { return (.unchanged, state) }

        let chunk = fresh.prefix(consumed)
        var text = (state.heldNewline ? "\n" : "") + String(decoding: chunk, as: UTF8.self)
        let holdsNewline = removeTrailingNewline(&text)

        let newOffset = state.offset + UInt64(consumed)
        let next = LogTailState(
            offset: newOffset,
            device: state.device,
            inode: state.inode,
            signature: signature(endingWith: data.prefix(state.signature.count + consumed)),
            heldNewline: holdsNewline
        )
        return (text.isEmpty ? .unchanged : .appended(text), next)
    }

    private static func readWindow(
        handle: FileHandle,
        size: UInt64,
        device: Int32,
        inode: UInt64,
        maxBytes: Int,
        maxLines: Int
    ) throws -> (result: LogTailResult, state: LogTailState?) {
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try handle.seek(toOffset: start)
        let data = try handle.read(upToCount: Int(size - start)) ?? Data()
        let consumed = completeUTF8Length(data)
        let chunk = data.prefix(consumed)

        var text = String(decoding: chunk, as: UTF8.self)
        // Reading from the middle of the file starts mid-line; drop that fragment.
        if start > 0, let firstNewline = text.utf8.firstIndex(of: 0x0A) {
            text.removeSubrange(...firstNewline)
        }
        let holdsNewline = removeTrailingNewline(&text)

        // Keep the newest `maxLines` lines.
        var newlines = 0
        var index = text.utf8.endIndex
        while index > text.utf8.startIndex {
            index = text.utf8.index(before: index)
            guard text.utf8[index] == 0x0A else { continue }
            newlines += 1
            if newlines == maxLines {
                text = String(text[text.utf8.index(after: index)...])
                break
            }
        }

        let state = LogTailState(
            offset: start + UInt64(consumed),
            device: device,
            inode: inode,
            signature: signature(endingWith: chunk),
            heldNewline: holdsNewline
        )
        return (.replaced(text), state)
    }

    private static func signature(endingWith data: Data) -> Data {
        Data(data.suffix(signatureLength))
    }

    /// Holds back one trailing newline (LF or CRLF); it is shown once more text follows.
    private static func removeTrailingNewline(_ text: inout String) -> Bool {
        guard text.utf8.last == 0x0A else { return false }
        text.removeLast()
        return true
    }

    /// Length of `data` without a trailing, incomplete UTF-8 sequence, so a character split
    /// across two reads is decoded once it is complete instead of as a replacement character.
    static func completeUTF8Length(_ data: Data) -> Int {
        let tail = Array(data.suffix(4))
        var back = 1
        while back <= tail.count {
            let byte = tail[tail.count - back]
            if byte & 0xC0 == 0x80 { back += 1; continue } // continuation byte
            let expected: Int
            switch byte {
            case 0x00...0x7F: expected = 1
            case 0xC0...0xDF: expected = 2
            case 0xE0...0xEF: expected = 3
            case 0xF0...0xF7: expected = 4
            default: return data.count
            }
            return back < expected ? data.count - back : data.count
        }
        return data.count
    }

    private static func message(forErrno code: Int32) -> String {
        switch code {
        case EACCES, EPERM: return "Permission denied: Nest is not allowed to read this file."
        default: return String(cString: strerror(code))
        }
    }

    // MARK: - Display window

    /// How many UTF-16 units to remove from the start of `text` so that at most `maxLines`
    /// lines and about `maxLength` units remain, cutting at a line boundary when possible.
    public static func overflowPrefixLength(of text: NSString, maxLines: Int, maxLength: Int) -> Int {
        let length = text.length
        guard length > 0 else { return 0 }
        let earliestKept = max(0, length - max(maxLength, 0))
        var newlines = 0
        var index = length
        while index > earliestKept {
            index -= 1
            if text.character(at: index) == 0x0A {
                newlines += 1
                if newlines >= maxLines { return index + 1 }
            }
        }
        guard earliestKept > 0 else { return 0 }
        let searchStart = earliestKept - 1
        let newline = text.range(of: "\n", options: .literal, range: NSRange(location: searchStart, length: length - searchStart))
        if newline.location != NSNotFound { return newline.location + 1 }
        // A single line longer than the window: cut inside it, but never through a character.
        return text.rangeOfComposedCharacterSequence(at: earliestKept).location
    }

    // MARK: - One-shot reading

    public static func load(
        path: String,
        maxBytes: Int = defaultMaxBytes,
        maxLines: Int = defaultMaxLines
    ) async -> String {
        await Task.detached(priority: .userInitiated) {
            read(path: path, maxBytes: maxBytes, maxLines: maxLines)
        }.value
    }

    /// The newest part of the log, or "" when it is missing or unreadable.
    public static func read(
        path: String,
        maxBytes: Int = defaultMaxBytes,
        maxLines: Int = defaultMaxLines
    ) -> String {
        guard case .replaced(let text) = poll(path: path, state: nil, maxBytes: maxBytes, maxLines: maxLines).result else {
            return ""
        }
        return text.trimmingCharacters(in: .newlines)
    }

    /// Empties a log in place. Services keep their file open in append mode, so replacing the
    /// file would leave them writing to an unlinked inode that no viewer can see.
    public static func truncate(path: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
    }
}
