import Foundation

public enum BrewServiceAction: String, Sendable { case start, stop, restart }

public enum BrewServiceController {
    public static var brewPath: String { "/opt/homebrew/bin/brew" }
}
