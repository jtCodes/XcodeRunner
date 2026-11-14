import AppKit

@main
struct PreviewMenuBarIcons {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let states: [(String, String?, NSColor)] = [
            ("Idle", nil, .clear), ("Build", "hammer.fill", .systemOrange),
            ("Unlock", "lock.fill", .systemOrange), ("Running", "play.fill", .systemGreen),
            ("Failed", "exclamationmark", .systemRed), ("Done", "checkmark", .systemGreen),
            ("Exited", "stop.fill", .systemGray)
        ]
        let preview = NSImage(size: NSSize(width: 784, height: 170), flipped: false) { _ in
            NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 784, height: 170).fill()
            for (index, state) in states.enumerated() {
                let x = CGFloat(index * 112)
                let icon = MenuBarIconRenderer.image(symbol: state.1, tint: state.2, dark: true)
                icon.draw(in: NSRect(x: x + 44, y: 128, width: 24, height: 22))
                icon.draw(in: NSRect(x: x + 20, y: 38, width: 72, height: 66))
                (state.0 as NSString).draw(at: NSPoint(x: x + 24, y: 12), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white
                ])
            }
            return true
        }
        guard let data = preview.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not render preview") }
        try png.write(to: root.appendingPathComponent("DesignAssets/MenuBar-preview.png"))
        print("Rendered app icon with all menu bar status badges.")
    }
}
