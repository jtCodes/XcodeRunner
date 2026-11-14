import AppKit

@MainActor
enum MenuBarIconRenderer {
    private static var cache: [String: NSImage] = [:]
    static func image(symbol: String?, tint: NSColor, dark: Bool = false) -> NSImage {
        let key = (symbol ?? "idle") + ":" + tint.description + ":" + String(dark)
        if let cached = cache[key] { return cached }
        let badge = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 6, weight: .bold))
        let image = NSImage(size: NSSize(width: 24, height: 22), flipped: false) { _ in
            // A native vector version of the app's code/play emblem, with no tile.
            let foreground: NSColor = dark ? .white : .black
            foreground.setStroke()
            foreground.setFill()
            let brackets = NSBezierPath()
            brackets.lineWidth = 1.8
            brackets.lineCapStyle = .round
            brackets.lineJoinStyle = .round
            brackets.move(to: NSPoint(x: 7, y: 18))
            brackets.line(to: NSPoint(x: 2, y: 12))
            brackets.line(to: NSPoint(x: 7, y: 6))
            brackets.move(to: NSPoint(x: 15, y: 18))
            brackets.line(to: NSPoint(x: 20, y: 12))
            brackets.line(to: NSPoint(x: 15, y: 6))
            brackets.stroke()
            let play = NSBezierPath()
            play.move(to: NSPoint(x: 9, y: 17))
            play.line(to: NSPoint(x: 16, y: 12))
            play.line(to: NSPoint(x: 9, y: 7))
            play.close()
            play.fill()
            if let badge {
                let badgeRect = NSRect(x: 14, y: 0, width: 10, height: 10)
                (dark ? NSColor.black : NSColor.white).setFill()
                NSBezierPath(ovalIn: badgeRect.insetBy(dx: -0.75, dy: -0.75)).fill()
                tint.setFill()
                NSBezierPath(ovalIn: badgeRect).fill()
                let whiteBadge = badge.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white])) ?? badge
                let size = whiteBadge.size
                let scale = min(6.0 / max(size.width, 1), 6.0 / max(size.height, 1))
                let width = size.width * scale
                let height = size.height * scale
                whiteBadge.draw(in: NSRect(x: badgeRect.midX - width / 2, y: badgeRect.midY - height / 2, width: width, height: height))
            }
            return true
        }
        image.isTemplate = false
        cache[key] = image
        return image
    }
}
