import Foundation
import Darwin

public enum PortInspector {
    public static func isPortInUse(_ port: Int) -> Bool {
        !pids(onPort: port).isEmpty
    }

    public static func waitForPortState(
        _ port: Int,
        inUse expectedState: Bool,
        timeoutNanoseconds: UInt64,
        pollNanoseconds: UInt32 = 150_000_000
    ) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds

        while DispatchTime.now().uptimeNanoseconds < deadline {
            if isPortInUse(port) == expectedState {
                return true
            }

            usleep(pollNanoseconds / 1_000)
        }

        return isPortInUse(port) == expectedState
    }

    public static func pids(onPort port: Int) -> [Int32] {
        guard (1...65_535).contains(port) else { return [] }
        let result = SystemProcess.capture("/usr/sbin/lsof", arguments: ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"])
        guard result.status == 0 else { return [] }
        return result.output
            .split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Every listening TCP port and the processes listening on it, from a single `lsof` call.
    public static func listeningSockets() -> [Int: Set<Int32>] {
        let result = SystemProcess.capture("/usr/sbin/lsof", arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pn"])
        // lsof exits 1 when nothing matches.
        guard result.status == 0 || result.status == 1 else { return [:] }
        return parseListeningSockets(result.output)
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
