import SwiftUI
import AppKit

struct ProjectOutputView: View {
    @ObservedObject var store: RunnerStore
    let projectID: UUID
    @State private var tab = "build"
    @State private var expanded = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).help(expanded ? "Collapse output" : "Expand output")
                Picker("Output", selection: $tab) {
                    Text("Build Output").tag("build")
                    Text("App Console").tag("console")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 250)
                Spacer()
            }.padding(.horizontal, 20).padding(.vertical, 10)
            if expanded {
                Group {
                if tab == "console" {
                    if let console = store.consoles[projectID] {
                        LiveConsoleView(console: console).id(console.id)
                    } else {
                        Text("Run the app to connect its live console.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else { buildOutput }
                }
                .frame(height: 270)
                .clipped()
            }
        }
        .onAppear {
            if store.consoles[projectID] != nil && store.activeID != projectID { tab = "console" }
        }
        .onChange(of: store.consoles[projectID]?.id) { _, id in
            if id != nil { tab = "console"; expanded = true }
        }
        .onChange(of: store.activeID) { _, active in
            if active == projectID { tab = "build" }
        }
    }
    private var buildOutput: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Build & deployment logs").foregroundStyle(.secondary)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { copyOutput(store.logs[projectID] ?? "") }
                    .buttonStyle(.plain).disabled(store.logs[projectID]?.isEmpty != false)
            }.font(.caption).padding(.horizontal, 24).frame(height: 32)
            ScrollView([.vertical, .horizontal]) {
                Text(store.logs[projectID] ?? "Build and deployment output will appear here.\nPress Run to begin.")
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
            }.frame(maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
        }
    }
}

private struct LiveConsoleView: View {
    @ObservedObject var console: AppConsoleSession
    @State private var filter = ""
    @State private var follow = true
    @State private var pausedText: String?
    private var visible: String {
        let text = follow ? console.text : pausedText ?? console.text
        return ConsoleText.filtered(text, query: filter)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label(console.status, systemImage: console.isRunning ? "waveform" : "circle")
                    .foregroundStyle(console.isRunning ? Color.green : Color.secondary)
                Spacer()
                TextField("Filter logs", text: $filter).textFieldStyle(.roundedBorder).frame(width: 180)
                Button(follow ? "Pause Scrolling" : "Resume", systemImage: follow ? "pause" : "play") {
                    if follow { pausedText = console.text; follow = false }
                    else { pausedText = nil; follow = true }
                }.buttonStyle(.plain)
                Menu {
                    Button("Clear Console", systemImage: "trash") { console.clear(); pausedText = follow ? nil : "" }
                    Button("Copy Visible Logs", systemImage: "doc.on.doc") { copyOutput(visible) }
                    Button("Copy All Logs") { copyOutput(console.text) }
                    Divider()
                    Button("Disconnect Console", systemImage: "stop") { console.stop() }.disabled(!console.isRunning)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 24).contentShape(Rectangle())
                }.menuStyle(.borderlessButton).fixedSize()
            }.font(.caption).padding(.horizontal, 24).frame(height: 32)
            NativeConsoleTextView(
                text: visible.isEmpty ? (filter.isEmpty ? "Waiting for app output…" : "No matching log lines.") : visible,
                follow: follow,
                onScrollAway: {
                    if follow { pausedText = console.text; follow = false }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
    }
}

private func copyOutput(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
