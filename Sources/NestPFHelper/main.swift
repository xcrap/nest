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

let existingAnchor = try? String(contentsOfFile: anchorPath, encoding: .utf8)
if existingAnchor != anchorContents {
    do {
        try anchorContents.write(toFile: anchorPath, atomically: true, encoding: .utf8)
        log("wrote \(anchorPath)")
    } catch {
        log("failed to write \(anchorPath): \(error)")
        exit(2)
    }
}

let pfConf = (try? String(contentsOfFile: pfConfPath, encoding: .utf8)) ?? ""
let alreadyWired = pfConf.contains(anchorDeclaration) && pfConf.contains(anchorLoad)

if !alreadyWired {
    var lines = pfConf.components(separatedBy: "\n")
    let insertIndex = lines.firstIndex { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("rdr-anchor") || trimmed.hasPrefix("load anchor")
    } ?? lines.count

    lines.insert(anchorLoad, at: insertIndex)
    lines.insert(anchorDeclaration, at: insertIndex)
    let updated = lines.joined(separator: "\n")

    if !pfConf.isEmpty, !FileManager.default.fileExists(atPath: pfConfBackupPath) {
        try? pfConf.write(toFile: pfConfBackupPath, atomically: true, encoding: .utf8)
    }

    do {
        try updated.write(toFile: pfConfPath, atomically: true, encoding: .utf8)
        log("updated \(pfConfPath) with Nest anchor")
    } catch {
        log("failed to update \(pfConfPath): \(error)")
        exit(3)
    }
}

let status = run("/sbin/pfctl", ["-Ef", pfConfPath])
if status != 0 {
    log("pfctl -Ef \(pfConfPath) exited \(status)")
}
exit(status)
