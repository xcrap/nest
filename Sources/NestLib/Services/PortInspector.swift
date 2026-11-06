import Foundation
import Darwin

public enum PortInspector {
    public static func pids(onPort port: Int) -> [Int32] {
        guard (1...65_535).contains(port) else { return [] }
        let result = SystemProcess.capture("/usr/sbin/lsof", arguments: ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"])
        guard result.status == 0 else { return [] }
        return result.output
            .split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Listeners on the given ports and the processes listening on them, from a single `lsof`
    /// call scoped to those ports (`-iTCP:p1,p2,…`) instead of every socket on the Mac.
    public static func listeningSockets(ports: [Int]) -> [Int: Set<Int32>] {
        guard let selector = tcpSelector(ports: ports) else { return [:] }
        let result = SystemProcess.capture("/usr/sbin/lsof", arguments: ["-nP", selector, "-sTCP:LISTEN", "-F", "pn"])
        // lsof exits 1 when nothing matches.
        guard result.status == 0 || result.status == 1 else { return [:] }
        return parseListeningSockets(result.output)
    }

    /// nil when no port is valid: an empty list must never widen to every port.
    public static func tcpSelector(ports: [Int]) -> String? {
        let valid = Set(ports.filter { (1...65_535).contains($0) }).sorted()
        guard !valid.isEmpty else { return nil }
        return "-iTCP:" + valid.map(String.init).joined(separator: ",")
    }

    /// Parses `lsof -F pn` output: `p<pid>` starts a process, `n<address>:<port>` names a socket.
    public static func parseListeningSockets(_ output: String) -> [Int: Set<Int32>] {
        var sockets: [Int: Set<Int32>] = [:]
        var currentPID: Int32?
        for line in output.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = line.dropFirst()
            switch field {
            case "p":
                currentPID = Int32(value)
            case "n":
                guard let pid = currentPID,
                      let separator = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: separator)...]) else { continue }
                sockets[port, default: []].insert(pid)
            default:
                continue
            }
        }
        return sockets
    }
}
