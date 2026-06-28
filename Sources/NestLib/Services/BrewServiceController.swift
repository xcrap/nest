import Foundation

public enum BrewServiceAction: String, Sendable {
    case start
    case stop
    case restart
}

public enum BrewServiceController {
    public static var brewPath: String {
        "/opt/homebrew/bin/brew"
    }

    public static func run(
        _ action: BrewServiceAction,
        service: String,
        completion: @escaping @Sendable (Bool, String?) -> Void
    ) {
        guard FileManager.default.isExecutableFile(atPath: brewPath) else {
            completion(false, "Homebrew is not available at \(brewPath). Set runtime paths or install the service manually.")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: brewPath)
        process.arguments = ["services", action.rawValue, service]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        process.terminationHandler = { proc in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            completion(proc.terminationStatus == 0, proc.terminationStatus == 0 ? nil : output)
        }

        do {
            try process.run()
        } catch {
            completion(false, error.localizedDescription)
        }
    }
}
