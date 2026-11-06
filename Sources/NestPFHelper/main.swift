import Foundation
import NestPFCore

let anchorPath = PFConfEditor.anchorPath
let pfConfPath = PFConfEditor.pfConfPath
let pfConfBackupPath = PFConfEditor.pfConfBackupPath
let anchorContents = PFConfEditor.anchorContents

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

/// Runs a command and returns its standard output; standard error still reaches the helper log.
func output(_ executable: String, _ args: [String]) -> (status: Int32, text: String) {
    let p = Process()
    let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = args
    p.standardOutput = pipe
    p.standardError = FileHandle.standardError
    do {
        try p.run()
    } catch {
        log("failed to spawn \(executable): \(error)")
        return (-1, "")
    }
    // Drain before waiting so a full pipe cannot block the child.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// `pfctl -E` takes another enable reference on every call (and the token is discarded), so
/// enable only when PF is off. If the status cannot be read, enable as before.
func pfNeedsEnabling() -> Bool {
    let info = output("/sbin/pfctl", ["-s", "info"])
    guard info.status == 0 else { return true }
    return !PFConfEditor.isEnabled(statusInfo: info.text)
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

    let arguments = enablePF && pfNeedsEnabling() ? ["-Ef", pfConfPath] : ["-f", pfConfPath]
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

        let updatedPFConf = try PFConfEditor.insertingManagedBlock(into: currentPFConf)
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
        let updatedPFConf = try PFConfEditor.removingManagedBlock(from: currentPFConf)
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
