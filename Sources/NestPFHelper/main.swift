import Foundation

let anchorName = "app.nest"
let anchorPath = "/etc/pf.anchors/\(anchorName)"
let pfConfPath = "/etc/pf.conf"
let pfConfBackupPath = "/etc/pf.conf.nest-backup"

let anchorContents = """
rdr pass on lo0 inet proto tcp from any to any port 80 -> 127.0.0.1 port 8080
rdr pass on lo0 inet proto tcp from any to any port 443 -> 127.0.0.1 port 8443

"""

let anchorDeclaration = "rdr-anchor \"\(anchorName)\""
let anchorLoad = "load anchor \"\(anchorName)\" from \"\(anchorPath)\""
let markerStart = "# BEGIN NEST PF ANCHOR"
let markerEnd = "# END NEST PF ANCHOR"
let managedPFBlock = """
\(markerStart)
\(anchorDeclaration)
\(anchorLoad)
\(markerEnd)
"""

func log(_ message: String) {
    let line = "[nest-pfhelper] \(message)\n"
    FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
}

@discardableResult
func run(_ executable: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = args
    p.standardOutput = FileHandle.standardOutput
    p.standardError = FileHandle.standardError
    do {
        try p.run()
    } catch {
        log("failed to spawn \(executable): \(error)")
        return -1
    }
    p.waitUntilExit()
    return p.terminationStatus
}

func write(_ contents: String, to path: String) throws {
    let directory = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
}

func restore(_ original: String?, to path: String) {
    do {
        if let original {
            try write(original, to: path)
            log("restored \(path)")
        } else if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
            log("removed \(path)")
        }
    } catch {
        log("failed to restore \(path): \(error)")
    }
}

func rollback(anchor: String?, pfConf: String?) {
    restore(anchor, to: anchorPath)
    restore(pfConf, to: pfConfPath)
}

struct UnbalancedMarkers: Error, CustomStringConvertible {
    var description: String { "\(pfConfPath) has unbalanced Nest markers; refusing to edit it" }
}

/// Removes only Nest's own lines. A start marker without its end marker would otherwise
/// swallow every rule after it, so that case is refused instead of guessed at.
func removingManagedPFBlock(from content: String) throws -> String {
    var output: [String] = []
    var insideManagedBlock = false

    for line in content.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == markerStart {
            guard !insideManagedBlock else { throw UnbalancedMarkers() }
            insideManagedBlock = true
            continue
        }
        if trimmed == markerEnd {
            guard insideManagedBlock else { throw UnbalancedMarkers() }
            insideManagedBlock = false
            continue
        }
        if insideManagedBlock {
            guard trimmed.isEmpty || trimmed == anchorDeclaration || trimmed == anchorLoad else { throw UnbalancedMarkers() }
            continue
        }
        if trimmed == anchorDeclaration || trimmed == anchorLoad {
            continue
        }
        output.append(line)
    }

    guard !insideManagedBlock else { throw UnbalancedMarkers() }
    return output.joined(separator: "\n")
}

func insertingManagedPFBlock(into content: String) throws -> String {
    let cleaned = try removingManagedPFBlock(from: content)
    var lines = cleaned.components(separatedBy: "\n")
    let insertIndex = lines.firstIndex { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("rdr-anchor") || trimmed.hasPrefix("load anchor")
    } ?? lines.count

    lines.insert(contentsOf: managedPFBlock.components(separatedBy: "\n"), at: insertIndex)
    return lines.joined(separator: "\n")
}

/// Keeps the first pristine copy (raw bytes) and refuses to continue if it cannot be written.
func backupPFConfIfNeeded(_ original: Data?) throws {
    guard let original, !original.isEmpty, !FileManager.default.fileExists(atPath: pfConfBackupPath) else { return }
    try original.write(to: URL(fileURLWithPath: pfConfBackupPath), options: .atomic)
    log("backed up \(pfConfPath) to \(pfConfBackupPath)")
}

struct UnreadableFile: Error, CustomStringConvertible {
    let path: String
    var description: String { "\(path) exists but is not valid UTF-8; refusing to edit it" }
}

/// nil only when the file does not exist. An existing file that cannot be decoded must never
/// be treated as empty: rewriting it would drop every system rule it contains.
func readExisting(_ path: String) throws -> (text: String, data: Data)? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let text = String(data: data, encoding: .utf8) else { throw UnreadableFile(path: path) }
    return (text, data)
}

func validateAndApply(originalAnchor: String?, originalPFConf: String?, enablePF: Bool) -> Never {
    let syntaxStatus = run("/sbin/pfctl", ["-nf", pfConfPath])
    if syntaxStatus != 0 {
        log("pfctl -nf \(pfConfPath) exited \(syntaxStatus); rolling back")
        rollback(anchor: originalAnchor, pfConf: originalPFConf)
        exit(syntaxStatus)
    }

    let arguments = enablePF ? ["-Ef", pfConfPath] : ["-f", pfConfPath]
    let status = run("/sbin/pfctl", arguments)
    if status != 0 {
        log("pfctl \(arguments.joined(separator: " ")) exited \(status); rolling back")
        rollback(anchor: originalAnchor, pfConf: originalPFConf)
        _ = run("/sbin/pfctl", ["-f", pfConfPath])
    }
    exit(status)
}

let originalAnchor: String?
let originalPFConfFile: (text: String, data: Data)?
do {
    originalAnchor = try readExisting(anchorPath)?.text
    originalPFConfFile = try readExisting(pfConfPath)
} catch {
    log("\(error); no changes made")
    exit(5)
}
let originalPFConf = originalPFConfFile?.text
let currentPFConf = originalPFConf ?? ""

let command = CommandLine.arguments.dropFirst().first ?? "install"

switch command {
case "install", "--install", "repair", "--repair":
    do {
        if originalAnchor != anchorContents {
            try write(anchorContents, to: anchorPath)
            log("wrote \(anchorPath)")
        }

        let updatedPFConf = try insertingManagedPFBlock(into: currentPFConf)
        if updatedPFConf != currentPFConf {
            try backupPFConfIfNeeded(originalPFConfFile?.data)
            try write(updatedPFConf, to: pfConfPath)
            log("updated \(pfConfPath) with Nest anchor")
        }
    } catch {
        log("failed to update PF files: \(error)")
        rollback(anchor: originalAnchor, pfConf: originalPFConf)
        exit(3)
    }

    validateAndApply(originalAnchor: originalAnchor, originalPFConf: originalPFConf, enablePF: true)

case "uninstall", "--uninstall":
    do {
        let updatedPFConf = try removingManagedPFBlock(from: currentPFConf)
        if updatedPFConf != currentPFConf {
            try backupPFConfIfNeeded(originalPFConfFile?.data)
            try write(updatedPFConf, to: pfConfPath)
            log("removed Nest anchor wiring from \(pfConfPath)")
        }

        if FileManager.default.fileExists(atPath: anchorPath) {
            try FileManager.default.removeItem(atPath: anchorPath)
            log("removed \(anchorPath)")
        }
    } catch {
        log("failed to uninstall PF files: \(error)")
        rollback(anchor: originalAnchor, pfConf: originalPFConf)
        exit(4)
    }

    validateAndApply(originalAnchor: originalAnchor, originalPFConf: originalPFConf, enablePF: false)

default:
    log("unknown command: \(command)")
    exit(64)
}
