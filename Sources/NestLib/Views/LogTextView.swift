import SwiftUI
import AppKit

/// Follows one log file. Reads run off the main thread and only new bytes are read; the
/// text view receives edits directly, so SwiftUI never diffs the log text.
@MainActor
final class LogTailModel: ObservableObject {
    enum Status: Equatable {
        case idle, loading, missing, unreadable(String), empty, content
    }

    @Published private(set) var status: Status = .idle
    private(set) var path = ""
    private var tailState: LogTailState?
    private var generation = 0
    private var reading = false
    private var readAgain = false
    private weak var textView: LogContainerView?

    /// Starts following `path`; the same path keeps the current position.
    func follow(path newPath: String) {
        guard newPath != path || status == .idle else { return }
        path = newPath
        restart()
    }

    /// Reads the file again from its newest window.
    func reload() { restart() }

    /// Picks up whatever was written since the last read.
    func refresh() {
        guard !path.isEmpty else { return }
        guard !reading else { readAgain = true; return }
        reading = true
        let path = self.path
        let state = tailState
        let generation = self.generation
        Task {
            let (result, next) = await Task.detached(priority: .userInitiated) {
                LogTailReader.poll(path: path, state: state)
            }.value
            self.reading = false
            if generation == self.generation { self.apply(result, next: next) }
            if self.readAgain || generation != self.generation {
                self.readAgain = false
                self.refresh()
            }
        }
    }

    fileprivate func attach(_ view: LogContainerView) {
        textView = view
        // A new text view starts empty; show the current window again. Deferred because
        // this runs inside a SwiftUI view update, where publishing is not allowed.
        guard !path.isEmpty else { return }
        Task { @MainActor [weak self] in self?.restart() }
    }

    private func restart() {
        generation += 1
        tailState = nil
        textView?.replace(with: "")
        status = path.isEmpty ? .idle : .loading
        refresh()
    }

    private func apply(_ result: LogTailResult, next: LogTailState?) {
        switch result {
        case .missing:
            textView?.replace(with: "")
            status = .missing
            tailState = nil
        case .unreadable(let message):
            textView?.replace(with: "")
            status = .unreadable(message)
            tailState = nil
        case .replaced(let text):
            guard let textView else { tailState = nil; return }
            textView.replace(with: text)
            status = text.isEmpty ? .empty : .content
            tailState = next
        case .appended(let text):
            guard let textView else { tailState = nil; return }
            textView.append(text)
            status = .content
            tailState = next
        case .unchanged:
            tailState = next
            if status == .loading { status = .empty }
        }
    }
}

struct LogTextView: NSViewRepresentable {
    let model: LogTailModel

    func makeNSView(context: Context) -> LogContainerView {
        let view = LogContainerView()
        model.attach(view)
        return view
    }

    func updateNSView(_ nsView: LogContainerView, context: Context) {}
}

final class LogContainerView: NSView {
    private let scrollView = NSScrollView()
    /// TextKit 1, so the scroll anchor can be measured with the layout manager.
    private let textView = NSTextView(usingTextLayoutManager: false)
    private let maxLines = LogTailReader.defaultMaxLines
    private let maxLength = LogTailReader.defaultMaxBytes
    private let textAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
        .foregroundColor: NSColor.textColor
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    /// Replaces everything (first read, truncation, rotation). Follows the end of the log
    /// unless the reader had scrolled up.
    func replace(with text: String) {
        guard let storage = textView.textStorage else { return }
        if text.isEmpty && storage.length == 0 { return }
        let followTail = storage.length == 0 || isScrolledToBottom
        let savedOrigin = scrollView.contentView.bounds.origin
        storage.setAttributedString(NSAttributedString(string: text, attributes: textAttributes))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        if followTail {
            textView.scrollToEndOfDocument(nil)
        } else {
            layoutAll()
            scroll(to: savedOrigin)
        }
    }

    /// Appends new lines and trims the oldest ones past the window, keeping the selection
    /// and the visible lines in place while the reader is scrolled up.
    func append(_ text: String) {
        guard !text.isEmpty, let storage = textView.textStorage else { return }
        let followTail = storage.length == 0 || isScrolledToBottom
        let anchor = followTail ? nil : topVisibleAnchor()
        let selection = textView.selectedRanges.map(\.rangeValue)

        storage.beginEditing()
        storage.append(NSAttributedString(string: text, attributes: textAttributes))
        let removed = LogTailReader.overflowPrefixLength(of: storage.mutableString, maxLines: maxLines, maxLength: maxLength)
        if removed > 0 { storage.deleteCharacters(in: NSRange(location: 0, length: removed)) }
        storage.endEditing()

        if removed > 0 {
            textView.selectedRanges = Self.shift(selection, by: removed, limit: storage.length)
        }

        if followTail {
            textView.scrollToEndOfDocument(nil)
        } else if let anchor {
            layoutAll()
            restore(anchor, removed: removed)
        }
    }

    // MARK: - Scroll position

    private struct Anchor {
        let characterIndex: Int
        let offset: CGFloat
        let x: CGFloat
    }

    private var isScrolledToBottom: Bool {
        let visible = scrollView.contentView.bounds
        return visible.maxY >= textView.frame.height - 24
    }

    private func layoutAll() {
        if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
    }

    /// The first visible character and how far the view is scrolled past its line.
    private func topVisibleAnchor() -> Anchor? {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer,
              textView.textStorage?.length ?? 0 > 0 else { return nil }
        let visible = scrollView.contentView.bounds
        let inset = textView.textContainerOrigin
        let point = NSPoint(x: 0, y: max(visible.minY - inset.y, 0))
        let glyph = layoutManager.glyphIndex(for: point, in: container)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        return Anchor(characterIndex: character, offset: visible.minY - (line.minY + inset.y), x: visible.minX)
    }

    private func restore(_ anchor: Anchor, removed: Int) {
        guard let layoutManager = textView.layoutManager else { return }
        let character = anchor.characterIndex - removed
        guard character >= 0, let length = textView.textStorage?.length, length > 0 else {
            scroll(to: NSPoint(x: anchor.x, y: 0))
            return
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(character, length - 1))
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        scroll(to: NSPoint(x: anchor.x, y: line.minY + textView.textContainerOrigin.y + anchor.offset))
    }

    private func scroll(to origin: NSPoint) {
        let maxY = max(textView.frame.height - scrollView.contentView.bounds.height, 0)
        scrollView.contentView.scroll(to: NSPoint(x: origin.x, y: min(max(origin.y, 0), maxY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Moves selections left by the trimmed prefix; a selection inside it collapses to the start.
    static func shift(_ ranges: [NSRange], by removed: Int, limit: Int) -> [NSValue] {
        let shifted = ranges.map { range -> NSRange in
            let start = max(range.location - removed, 0)
            let end = min(max(range.location + range.length - removed, 0), limit)
            return NSRange(location: min(start, limit), length: max(end - start, 0))
        }
        return (shifted.isEmpty ? [NSRange(location: 0, length: 0)] : shifted).map { NSValue(range: $0) }
    }

    private func setup() {
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFontPanel = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.setAccessibilityLabel("Log output")

        scrollView.documentView = textView

        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}
