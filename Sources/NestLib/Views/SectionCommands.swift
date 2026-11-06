import SwiftUI
import AppKit

private struct SidebarSelectionKey: FocusedValueKey {
    typealias Value = Binding<SidebarItem>
}

public extension FocusedValues {
    /// The focused window's sidebar section, for the View menu commands.
    var sidebarSelection: Binding<SidebarItem>? {
        get { self[SidebarSelectionKey.self] }
        set { self[SidebarSelectionKey.self] = newValue }
    }
}

/// View menu: Toggle Sidebar (⌘B) and one ⌘1…⌘6 item per sidebar section.
public struct SectionCommands: Commands {
    @FocusedBinding(\.sidebarSelection) private var selection

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            Button("Toggle Sidebar") {
                NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("b", modifiers: .command)

            Divider()

            ForEach(Array(SidebarItem.allCases.enumerated()), id: \.element) { index, item in
                Button(item.rawValue) { selection = item }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .disabled(selection == nil)
            }
        }
    }
}
