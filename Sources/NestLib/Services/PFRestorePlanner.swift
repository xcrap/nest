import Foundation

public enum PFRestoreDecision: Equatable {
    case skipFrankenPHPStopped
    case skipRedirectAlreadyWorking
    case reloadPF
}

public enum PFRestorePlanner {
    public static func decision(frankenphpRunning: Bool, redirectWorking: Bool) -> PFRestoreDecision {
        guard frankenphpRunning else { return .skipFrankenPHPStopped }
        return redirectWorking ? .skipRedirectAlreadyWorking : .reloadPF
    }
}
