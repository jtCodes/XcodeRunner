import SwiftUI
import AppKit

private extension NSAttributedString.Key { static let diffLineKind = Self("XcodeRunnerDiffLineKind") }

/// TextKit keeps long diffs selectable and scrollable without a SwiftUI view per line.
struct NativeDiffTextView: NSViewRepresentable {
    let document: GitDiffDocument
    let identity: String
    let swift: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.backgroundColor = .textBackgroundColor
        let storage = NSTextStorage()
        let layout = DiffLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true; container.lineFragmentPadding = 0
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        layout.allowsNonContiguousLayout = true
        let text = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize), textContainer: container)
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.backgroundColor = .textBackgroundColor
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.isContinuousSpellCheckingEnabled = false; text.isAutomaticLinkDetectionEnabled = false
        text.allowsUndo = false
        text.setAccessibilityLabel("Code diff with old and new line numbers")
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.documentID != document.id, let text = scroll.documentView as? NSTextView else { return }
        let offset = scroll.contentView.bounds.origin
        let selection = text.selectedRange()
        let sameFile = context.coordinator.identity == identity
        text.textStorage?.setAttributedString(DiffRenderer.render(document, swift: swift))
        if sameFile {
            let length = text.string.utf16.count
            text.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            scroll.contentView.scroll(to: offset); scroll.reflectScrolledClipView(scroll.contentView)
        } else { text.scrollToBeginningOfDocument(nil) }
        context.coordinator.documentID = document.id; context.coordinator.identity = identity
    }
    final class Coordinator { var documentID: UUID?; var identity: String? }
}

private final class DiffLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, _, container, glyphs, _ in
            guard glyphs.length > 0, let storage = self.textStorage else { return }
            let index = self.characterIndexForGlyph(at: glyphs.location)
            guard index < storage.length, let kind = storage.attribute(.diffLineKind, at: index, effectiveRange: nil) as? Int else { return }
            let color: NSColor
            switch kind {
            case 1: color = NSColor.systemGreen.withAlphaComponent(0.15)
            case -1: color = NSColor.systemRed.withAlphaComponent(0.15)
            default: color = NSColor.controlBackgroundColor
            }
            color.setFill()
            NSRect(x: origin.x, y: origin.y + rect.minY, width: container.size.width, height: rect.height).fill()
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

private enum DiffRenderer {
    static let tokens = try! NSRegularExpression(pattern: #"//.*$|\"(?:\\.|[^\"\\])*\"|\b(?:actor|as|async|await|break|case|catch|class|continue|default|defer|do|else|enum|extension|false|fileprivate|for|func|guard|if|import|in|init|internal|is|let|nil|override|private|protocol|public|repeat|rethrows|return|self|some|static|struct|super|switch|throw|throws|true|try|typealias|var|where|while)\b|\b[0-9]+(?:\.[0-9]+)?\b|\b[A-Z][A-Za-z0-9_]*\b"#)
    static func render(_ document: GitDiffDocument, swift: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let maximum = document.lines.compactMap { max($0.oldLine ?? 0, $0.newLine ?? 0) }.max() ?? 0
        let digits = max(3, String(maximum).count)
        func number(_ value: Int?) -> String {
            let text = value.map(String.init) ?? ""
            return String(repeating: " ", count: max(0, digits - text.count)) + text
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 3
        paragraph.headIndent = CGFloat((digits * 2 + 5)) * font.maximumAdvancement.width
        for line in document.lines {
            let marker = line.kind == .addition ? "+" : line.kind == .deletion ? "−" : " "
            let prefix = "\(number(line.oldLine)) \(number(line.newLine)) \(marker) "
            let row = NSMutableAttributedString(string: prefix + line.text + "\n", attributes: [
                .font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph
            ])
            row.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: prefix.utf16.count))
            switch line.kind {
            case .addition: row.addAttribute(.diffLineKind, value: 1, range: NSRange(location: 0, length: row.length))
            case .deletion: row.addAttribute(.diffLineKind, value: -1, range: NSRange(location: 0, length: row.length))
            case .hunk:
                row.addAttribute(.diffLineKind, value: 0, range: NSRange(location: 0, length: row.length))
                fallthrough
            case .metadata:
                row.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: row.length))
            case .context: break
            }
            if swift && [.addition, .deletion, .context].contains(line.kind) {
                let source = line.text as NSString
                for match in tokens.matches(in: line.text, range: NSRange(location: 0, length: source.length)) {
                    let token = source.substring(with: match.range)
                    let color: NSColor
                    if token.hasPrefix("//") { color = .secondaryLabelColor }
                    else if token.hasPrefix("\"") { color = .systemRed }
                    else if token.first?.isNumber == true { color = .systemOrange }
                    else if token.first?.isUppercase == true { color = .systemPurple }
                    else { color = .systemPink }
                    row.addAttribute(.foregroundColor, value: color, range: NSRange(location: prefix.utf16.count + match.range.location, length: match.range.length))
                }
            }
            result.append(row)
        }
        return result
    }
}
