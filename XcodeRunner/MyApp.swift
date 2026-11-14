import SwiftUI
import AppKit

@main
struct XcodeRunnerApp: App {
    @StateObject private var store = RunnerStore()
    @NSApplicationDelegateAdaptor(RunnerAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView().environmentObject(store)
                .onAppear { appDelegate.store = store }
        }
        .defaultSize(width: 1120, height: 820)
        .commands {
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
