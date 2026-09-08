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

}
