import Foundation

public enum LogTailReader {
    public static let defaultMaxBytes = 128_000
    public static let defaultMaxLines = 2_000

    public static func load(
        path: String,
        maxBytes: Int = defaultMaxBytes,
        maxLines: Int = defaultMaxLines
    ) async -> String {
        await Task.detached(priority: .userInitiated) {
            read(path: path, maxBytes: maxBytes, maxLines: maxLines)
        }.value
    }

    public static func read(
        path: String,
        maxBytes: Int = defaultMaxBytes,
        maxLines: Int = defaultMaxLines
    ) -> String {
        guard !path.isEmpty, maxBytes > 0, maxLines > 0 else {
            return ""
        }

        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ""
        }
        defer { try? handle.close() }

        do {
            let endOffset = try handle.seekToEnd()
            let startOffset = endOffset > UInt64(maxBytes)
                ? endOffset - UInt64(maxBytes)
                : 0

            try handle.seek(toOffset: startOffset)
            let data = try handle.read(upToCount: maxBytes) ?? Data()
            return normalize(data: data, truncatedAtStart: startOffset > 0, maxLines: maxLines)
        } catch {
            return ""
        }
    }

    private static func normalize(data: Data, truncatedAtStart: Bool, maxLines: Int) -> String {
        guard !data.isEmpty else {
            return ""
        }

        var text = String(decoding: data, as: UTF8.self)

        if truncatedAtStart, let firstNewline = text.firstIndex(of: "\n") {
            text.removeSubrange(text.startIndex...firstNewline)
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > maxLines {
            text = lines.suffix(maxLines).joined(separator: "\n")
        }

        return text.trimmingCharacters(in: .newlines)
    }
}
