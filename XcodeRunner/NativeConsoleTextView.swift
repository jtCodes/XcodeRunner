import SwiftUI
import AppKit

/// Native text storage and noncontiguous layout avoid rebuilding a SwiftUI Text
/// for every log batch, while keeping wrapping and cross-line selection.
struct NativeConsoleTextView: NSViewRepresentable {
    let text: String
    let follow: Bool
    let onScrollAway: () -> Void
    var accessibilityLabel = "Log output"

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ConsoleScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 16, height: 12)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.allowsUndo = false
        textView.setAccessibilityLabel(accessibilityLabel)
        scroll.documentView = textView
        context.coordinator.onScrollAway = onScrollAway
        scroll.onScrollAway = { [weak coordinator = context.coordinator] in coordinator?.scheduleScrollAway() }
        context.coordinator.observe(scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView, let storage = textView.textStorage else { return }
        let coordinator = context.coordinator
        coordinator.isApplyingUpdate = true
        defer { coordinator.isApplyingUpdate = false }
        coordinator.onScrollAway = onScrollAway
        textView.setAccessibilityLabel(accessibilityLabel)
        let changed = coordinator.previous != text
        let resumed = follow && !coordinator.followed
        coordinator.followed = follow
        guard changed || resumed else { return }
        if changed {
            let update = ConsoleTextUpdate.between(coordinator.previous, and: text)
            let selection = textView.selectedRange()
            storage.beginEditing()
            if update.removedPrefix > 0 { storage.deleteCharacters(in: NSRange(location: 0, length: update.removedPrefix)) }
            if !update.appended.isEmpty {
                storage.append(NSAttributedString(string: update.appended, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.textColor
                ]))
            }
            storage.endEditing()
            // Preserve selection across appends and bounded-buffer prefix trims.
            let start = update.replacesAll ? 0 : min(storage.length, max(0, selection.location - update.removedPrefix))
            let end = update.replacesAll ? 0 : min(storage.length, max(start, NSMaxRange(selection) - update.removedPrefix))
            textView.setSelectedRange(NSRange(location: start, length: end - start))
            coordinator.previous = text
        }
        if follow { textView.scrollRangeToVisible(NSRange(location: storage.length, length: 0)) }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) { coordinator.stopObserving() }

    final class Coordinator {
        var previous = ""
        var followed = false
        var onScrollAway: (() -> Void)?
        private var observer: NSObjectProtocol?
        var isApplyingUpdate = false
        private var scrollCallbackPending = false
        private var active = true
        func scheduleScrollAway() {
            guard active, followed, !isApplyingUpdate, !scrollCallbackPending else { return }
            scrollCallbackPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scrollCallbackPending = false
                guard self.active, self.followed, !self.isApplyingUpdate else { return }
                self.onScrollAway?()
            }
        }
        func observe(_ scroll: NSScrollView) {
            observer = NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification,
                object: scroll, queue: .main) { [weak self, weak scroll] _ in
                    guard let scroll, let document = scroll.documentView,
                          scroll.contentView.bounds.maxY < document.bounds.maxY - 2 else { return }
                    self?.scheduleScrollAway()
                }
        }
        func stopObserving() {
            active = false
            onScrollAway = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
        deinit { stopObserving() }
    }
}

private final class ConsoleScrollView: NSScrollView {
    var onScrollAway: (() -> Void)?
    override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaY > 0 { onScrollAway?() }
        super.scrollWheel(with: event)
    }
}
