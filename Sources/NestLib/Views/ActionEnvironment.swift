import SwiftUI

private struct ActionProcessControllerKey: EnvironmentKey {
    static let defaultValue: ProcessController? = nil
}

public extension EnvironmentValues {
    /// The process controller, for reading service state when an action runs. Unlike
    /// `@EnvironmentObject`, reading it does not re-render the view on every status change.
    var actionProcessController: ProcessController? {
        get { self[ActionProcessControllerKey.self] }
        set { self[ActionProcessControllerKey.self] = newValue }
    }
}
