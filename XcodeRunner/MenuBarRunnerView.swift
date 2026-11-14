import SwiftUI
import AppKit

struct MenuBarRunnerView: View {
    @ObservedObject var store: RunnerStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("XcodeRunner").font(.headline)
                Spacer()
                Button("Open Window", systemImage: "macwindow") { showWindow() }
                    .buttonStyle(.plain).font(.caption)
            }
            if store.projects.isEmpty {
                Text("Add a project to get started.").foregroundStyle(.secondary)
                Button("Add Project…", systemImage: "plus") { showWindow(); store.addProject() }
                    .disabled(store.importing)
            } else {
                Picker("Project", selection: $store.selection) {
                    if store.selection == nil { Text("Choose a project").tag(nil as UUID?) }
                    ForEach(store.sortedProjects) { project in Text(project.name).tag(Optional(project.id)) }
                }
                if let project = store.selected {
                    Text(project.scheme.isEmpty ? "Choose a scheme in the main window" : "\(project.scheme) · \(project.configuration)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Picker("Destination", selection: Binding(get: {
                        store.projects.first { $0.id == project.id }?.destinationID ?? ""
                    }, set: { id in
                        guard id != project.destinationID else { return }
                        store.update(project.id) { $0.destinationID = id }
                    })) {
                        Text("Choose a destination").tag("")
                        if !project.destinationID.isEmpty && !store.destinations.contains(where: { $0.id == project.destinationID }) {
                            Text("Saved device unavailable").tag(project.destinationID)
                        }
                        Section("Devices") {
                            ForEach(store.destinations.filter { $0.kind == .device }) { Text($0.label).tag($0.id) }
                        }
                        Section("Simulators") {
                            ForEach(store.destinations.filter { $0.kind == .simulator }) { Text($0.label + " · " + $0.detail).tag($0.id) }
                        }
                    }.disabled(store.activeID == project.id || store.queue.contains(project.id))
                    ProjectToolbarStatus(store: store, project: project)
                    HStack {
                        if store.activeID == project.id {
                            Button("Stop", systemImage: "stop.fill") { store.stop() }
                        } else if store.queue.contains(project.id) {
                            Button("Unqueue", systemImage: "xmark") { store.unqueue(project.id) }
                        } else {
                            Button(store.activeID == nil ? "Run" : "Queue Run", systemImage: "play.fill") { store.enqueue(project.id) }
                                .buttonStyle(.borderedProminent).disabled(!store.canRun(project))
                            Button("Launch Again") { store.launchAgain(project) }
                                .disabled(store.activeID != nil || !store.canLaunch(project))
                        }
                        Spacer()
                    }
                }
                if let active = store.projects.first(where: { $0.id == store.activeID }), active.id != store.selection {
                    HStack {
                        Text("\(active.name): \(store.statuses[active.id] ?? "Running")").font(.caption).lineLimit(2)
                        Spacer()
                        Button("Stop") { store.stop() }
                    }
                }
                if !store.queue.isEmpty { Text("\(store.queue.count) queued").font(.caption).foregroundStyle(.secondary) }
            }
            Divider()
            HStack {
                Text(store.loadingDevices ? "Refreshing devices…" : "Logs and settings in the main window")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { store.shutdown(); NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain).font(.caption)
            }
        }
        .padding(20).frame(width: 360)
        .task { await store.refreshDevices() }
    }
    private func showWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
