import SwiftUI
import AppKit

@main
struct XcodeRunnerApp: App {
    @StateObject private var store = RunnerStore()
    @AppStorage("XcodeRunner.outputVisible") private var outputVisible = true
    @NSApplicationDelegateAdaptor(RunnerAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView().environmentObject(store)
                .onAppear { appDelegate.store = store }
        }
        .defaultSize(width: 1120, height: 820)
        .commands {
            CommandMenu("Run") {
                Button("Run Selected Project") { store.runSelectedProject() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!store.canRunSelectedProject)
                Divider()
                Button("Archive → Open in Xcode Organizer") {
                    if let project = store.selected { store.archive(project) }
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(store.selected.map { !store.canArchive($0) } ?? true)
                Button("Open Last Archive in Xcode") {
                    if let project = store.selected { store.openLastArchive(project) }
                }.disabled(store.selected?.lastArchivePath == nil)
            }
            CommandGroup(after: .toolbar) {
                Toggle("Expand Output", isOn: $outputVisible)
                    .keyboardShortcut("y", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Project…") { store.addProject() }.keyboardShortcut("o", modifiers: .command)
            }
        }
        MenuBarExtra {
            MenuBarRunnerView(store: store)
                .onAppear { appDelegate.store = store }
        } label: {
            MenuBarStatusIcon(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class RunnerAppDelegate: NSObject, NSApplicationDelegate {
    weak var store: RunnerStore?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { store?.shutdown() }
}
