import SwiftUI
import AppKit

struct MenuBarStatusIcon: View {
    @ObservedObject var store: RunnerStore
    @Environment(\.colorScheme) private var colorScheme

    private var indicator: (symbol: String?, tint: NSColor, description: String) {
        if let id = store.activeID, let project = store.projects.first(where: { $0.id == id }) {
            let status = store.statuses[id] ?? "Running"
            let symbol: String
            if store.waitingForUnlockID == id { symbol = "lock.fill" }
            else if status == "Installing" { symbol = "arrow.down" }
            else if status == "Launching" || status == "Starting simulator" { symbol = "play.fill" }
            else { symbol = "hammer.fill" }
            return (symbol, .systemOrange, "XcodeRunner · \(project.name): \(status)")
        }
        let last = store.lastFinishedID
        let status = last.flatMap { store.statuses[$0] }
        if status == "Failed" {
            return ("exclamationmark", .systemRed, "XcodeRunner · Run failed. Open for details.")
        }
        let running = store.projects.filter { store.menuAppStates[$0.id] == .running }
        if !running.isEmpty {
            return ("play.fill", .systemGreen, "XcodeRunner · App running: " + running.map(\.name).joined(separator: ", "))
        }
        if let last, store.menuAppStates[last] == .exited {
            return ("stop.fill", .systemGray, "XcodeRunner · App exited")
        }
        if status == "Cancelled" { return ("stop.fill", .systemGray, "XcodeRunner · Run cancelled") }
        if status == "Run succeeded" || status == "Launched" {
            return ("checkmark", .systemGreen, "XcodeRunner · Last run succeeded; no app currently tracked as running")
        }
        return (nil, .clear, "XcodeRunner · Ready")
    }
    var body: some View {
        let indicator = indicator
        // Render one NSImage because MenuBarExtra labels do not reliably retain
        // arbitrary SwiftUI overlay layouts when promoted into the status item.
        Image(nsImage: MenuBarIconRenderer.image(symbol: indicator.symbol, tint: indicator.tint, dark: colorScheme == .dark))
            .renderingMode(.original)
            .help(indicator.description)
            .accessibilityLabel(indicator.description)
    }
}

