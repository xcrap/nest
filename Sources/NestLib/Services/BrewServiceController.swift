import Foundation

public enum BrewServiceAction: String, Sendable { case start, stop, restart }

public enum BrewServiceController {
    public static var brewPath: String { "/opt/homebrew/bin/brew" }

    public static func run(_ action: BrewServiceAction, service: String,
                           completion: @escaping @Sendable (Bool, String?) -> Void) {
        Task.detached {
            let result = SystemProcess.capture(brewPath, arguments: ["services", action.rawValue, service], timeout: 120)
            completion(result.status == 0, result.status == 0 ? nil : result.output)
        }
    }
}
