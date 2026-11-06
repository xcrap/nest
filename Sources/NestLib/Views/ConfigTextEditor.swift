import SwiftUI
import AppKit

/// A plain-text code editor for configuration files. Unlike `TextEditor`, it never applies
/// the system's smart quotes, smart dashes, text replacement, autocorrect or spell checking,
/// which would silently corrupt php.ini, my.cnf or Caddy syntax.
struct ConfigTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true
    var accessibilityLabel: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        // AppKit's standard wrapping text view in a scroll view (sizing and resizing set up).
        let scrollView = NSTextView.scrollableTextView()
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.enabledTextCheckingTypes = 0

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.font = font
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
        textView.textColor = .textColor
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 6, height: 8)

        textView.string = text
        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.setAccessibilityLabel(accessibilityLabel)
        context.coordinator.syncedText = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.isEditable != isEditable { textView.isEditable = isEditable }
        textView.setAccessibilityLabel(accessibilityLabel)

        // Only push text the view did not produce itself (load, discard, restore). Typing
        // flows the other way and must not reset the selection or the undo stack.
        guard text != coordinator.syncedText else { return }
        let selection = textView.selectedRange()
        textView.string = text
        coordinator.syncedText = text
        let length = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        coordinator.undoManager.removeAllActions()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        /// The text last exchanged with SwiftUI, compared instead of bridging the view's string.
        var syncedText = ""
        /// Per-editor undo history, so ⌘Z never reaches into another file's edits.
        let undoManager = UndoManager()

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let value = textView.string
            syncedText = value
            text.wrappedValue = value
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }
    }
}
