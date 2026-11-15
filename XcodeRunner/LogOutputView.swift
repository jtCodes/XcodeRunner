import SwiftUI
import AppKit

/// One viewer for both build/deployment output and live app output.
struct LogOutputView: View {
    let text: String
    let status: String
    let symbol: String
    var live = false
    let placeholder: String
    var clear: (() -> Void)?
    var disconnect: (() -> Void)?
    @State private var filter = ""
    @State private var follow = true
    @State private var pausedText: String?

    private var visible: String { ConsoleText.filtered(follow ? text : pausedText ?? text, query: filter) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label(status, systemImage: symbol).lineLimit(1)
                    .foregroundStyle(live ? Color.green : Color.secondary).help(status)
                Spacer(minLength: 8)
                TextField("Filter logs", text: $filter).textFieldStyle(.roundedBorder).frame(width: 180)
                Button(follow ? "Pause Scrolling" : "Resume", systemImage: follow ? "pause" : "play") {
                    if follow { pause() } else { pausedText = nil; follow = true }
                }.buttonStyle(.plain)
                Button { copy(visible) } label: {
                    Image(systemName: "doc.on.doc").frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Copy visible logs").disabled(visible.isEmpty)
                Menu {
                    Button("Copy All Logs") { copy(text) }.disabled(text.isEmpty)
                    if let clear {
                        Button("Clear", systemImage: "trash") { clear(); pausedText = follow ? nil : "" }
                    }
                    if let disconnect {
                        Divider()
                        Button("Disconnect Console", systemImage: "stop", action: disconnect).disabled(!live)
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 24).contentShape(Rectangle())
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }.font(.caption).padding(.horizontal, 24).frame(height: 32)
            NativeConsoleTextView(
                text: visible.isEmpty ? (filter.isEmpty ? placeholder : "No matching log lines.") : visible,
                follow: follow,
                onScrollAway: pause,
                accessibilityLabel: status
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
    }
    private func pause() {
        guard follow else { return }
        pausedText = text
        follow = false
    }
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
