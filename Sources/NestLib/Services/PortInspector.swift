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

    public static func killProcesses(onPort port: Int) {
        for pid in pids(onPort: port) {
            killProcess(pid)
        }
    }

    public static func pids(onPort port: Int) -> [Int32] {
        guard (1...65_535).contains(port) else { return [] }
        let result = SystemProcess.capture("/usr/sbin/lsof", arguments: ["-ti", ":\(port)"])
        guard result.status == 0 else { return [] }
        return result.output
            .split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func killProcess(_ pid: Int32) {
        guard pid > 0 else { return }
        _ = Darwin.kill(pid, SIGTERM)
        usleep(500_000)
        _ = Darwin.kill(pid, SIGKILL)
    }
}
