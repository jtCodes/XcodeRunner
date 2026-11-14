import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var store: RunnerStore
    @State private var showChanges = true
    @State private var showDestinations = false
    @State private var selectedProjectIDs: Set<UUID> = []

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let project = store.selected { dashboard(project) }
            else { emptyState }
        }
        .navigationTitle("XcodeRunner")
        .frame(minWidth: 980, minHeight: 680)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if let project = store.selected { toolbarRunControls(project) }
            }
            ToolbarItem(placement: .principal) {
                if let project = store.selected {
                    HStack(spacing: 14) {
                        destinationPicker(project)
                        ProjectToolbarStatus(store: store, project: project)
                    }
                    .padding(.horizontal, 14)
                }
            }

        }
        .sheet(item: $store.pendingImport) { review in
            ProjectImportReviewView(review: review, cancel: store.cancelImportReview, confirm: store.confirmImport)
                .interactiveDismissDisabled()
        }
        .alert("XcodeRunner", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK") { store.message = nil }
        } message: { Text(store.message ?? "") }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedProjectIDs) {
                Section("Projects · \(store.projects.count)") {
                    ForEach(store.sortedProjects) { project in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: project.containerPath.hasSuffix(".xcworkspace") ? "square.stack" : "app")
                                .font(.system(size: 16, weight: .regular))
                                .foregroundStyle(.secondary).frame(width: 22).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(project.name).font(.system(.body, weight: .medium)).lineLimit(1)
                                Text(sidebarStatus(project)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if store.activeID == project.id { ProgressView().controlSize(.small) }
                            else if let count = store.changes[project.id]?.count, count > 0 {
                                Text("\(count)").font(.caption.monospacedDigit()).padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(.quaternary, in: Capsule())
                            }
                        }.padding(.vertical, 4).tag(project.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button(ids.count == 1 ? "Remove Project" : "Remove Selected Projects", systemImage: "trash", role: .destructive) {
                    store.removeProjects(ids)
                }.disabled(store.removableProjectIDs(from: ids).isEmpty)
            }
            .onDeleteCommand { store.removeProjects(selectedProjectIDs) }
            .task(id: selectedProjectIDs) {
                let ids = selectedProjectIDs
                // AppKit-backed List can write selection while reconciling rows.
                // Publish the detail selection after that view update completes.
                await Task.yield()
                guard !Task.isCancelled, selectedProjectIDs == ids else { return }
                if let current = store.selection, ids.contains(current) { return }
                let next = store.sortedProjects.first { ids.contains($0.id) }?.id
                if store.selection != next { store.selection = next }
            }
            .onAppear { syncProjectSelection() }
            .onChange(of: store.selection) { _, _ in syncProjectSelection() }
            .onChange(of: store.projects.map(\.id)) { _, ids in
                selectedProjectIDs.formIntersection(ids)
                syncProjectSelection()
            }
            Divider()
            HStack(spacing: 6) {
                Button { store.addProject() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(store.importing)
                .help("Add Project…").accessibilityLabel("Add Project")
                Button { store.removeProjects(selectedProjectIDs) } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(store.removableProjectIDs(from: selectedProjectIDs).isEmpty)
                .help("Remove selected projects from the list; files stay on disk")
                .accessibilityLabel("Remove Selected Projects")
                Spacer(minLength: 8)
                if store.importing {
                    ProgressView().controlSize(.small)
                    Text(store.importStatus ?? "Importing…")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(store.importStatus ?? "Importing projects")
                } else if selectedProjectIDs.count > 1 {
                    Text("\(selectedProjectIDs.count) selected").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }.navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
    }

    private func syncProjectSelection() {
        if let current = store.selection {
            if !selectedProjectIDs.contains(current) { selectedProjectIDs = [current] }
        } else { selectedProjectIDs = [] }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "hammer").font(.system(size: 48, weight: .light)).foregroundStyle(.tint)
            Text("From changes to your iPhone.").font(.largeTitle.bold())
            Text("Add your projects, choose a device, and run.\nXcode can stay closed.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Add Your First Project", systemImage: "plus") { store.addProject() }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(store.importing)
            if store.importing { ProgressView(store.importStatus ?? "Importing projects…").controlSize(.small) }
            Text("Local builds · Manual runs · Apple’s command-line tools")
                .font(.caption).foregroundStyle(.tertiary).padding(.top, 12)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dashboard(_ project: TrackedProject) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header(project)
                    settings(project)
                    runBar(project)
                    if project.baseline != nil { changeList(project) }
                }.padding(28)
            }
            Divider()
            outputPanel(project)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .id(project.id)
    }

    private func header(_ project: TrackedProject) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text("LOCAL PROJECT").font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(.secondary)
                Text(project.name).font(.system(size: 30, weight: .bold))
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.containerPath)])
                } label: {
                    Label(project.rootPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"), systemImage: "folder")
                        .font(.caption).lineLimit(1).truncationMode(.middle)
                }.buttonStyle(.plain).foregroundStyle(.secondary).help("Show in Finder")
            }
            Spacer()
            Menu {
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.containerPath)])
                }
                Button("Refresh Schemes", systemImage: "arrow.clockwise") {
                    Task { await store.refreshSchemes(project.id) }
                }.disabled(store.activeID == project.id || store.queue.contains(project.id))
                Divider()
                Button("Remove Project", systemImage: "trash", role: .destructive) { store.remove(project.id) }
                    .disabled(store.activeID == project.id || store.queue.contains(project.id))
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24).contentShape(Rectangle()) }
                .menuStyle(.borderlessButton).fixedSize()
        }
    }

    private func toolbarRunControls(_ project: TrackedProject) -> some View {
        HStack(spacing: 8) {
            if store.activeID == project.id {
                Button("Stop", systemImage: "stop.fill") { store.stop() }
                    .help("Cancel the current build or launch")
            } else if store.queue.contains(project.id) {
                Button("Unqueue", systemImage: "xmark") { store.unqueue(project.id) }
            } else {
                Button(store.activeID == nil ? "Run" : "Queue Run", systemImage: "play.fill") {
                    store.enqueue(project.id)
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!store.canRun(project))
                .help("Build, install, and launch the selected scheme")
                Menu {
                    Button("Launch Again", systemImage: "arrow.clockwise") { store.launchAgain(project) }
                        .disabled(store.activeID != nil || !store.canLaunch(project))
                } label: { Image(systemName: "chevron.down").frame(width: 16, height: 22).contentShape(Rectangle()) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .padding(.horizontal, 4).fixedSize().help("More run actions")
            }
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
    }

    private func destinationPicker(_ project: TrackedProject) -> some View {
        let selected = store.destinations.first { $0.id == project.destinationID }
        return Button { showDestinations.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: selected?.kind == .simulator ? "iphone.gen3" : "iphone")
                        .foregroundStyle(.secondary)
                    Text(selected?.name ?? (project.destinationID.isEmpty ? "Choose a destination" : "Device unavailable"))
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(width: 210).contentShape(Rectangle())
            }
        .buttonStyle(.plain)
        .disabled(store.activeID == project.id || store.queue.contains(project.id))
        .help("Run destination for \(project.name)")
        .popover(isPresented: $showDestinations, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Run Destination").font(.headline)
                    Spacer()
                    if store.loadingDevices { ProgressView().controlSize(.small) }
                }.padding(16)
                List {
                    Button("Choose a destination") {
                        store.update(project.id) { $0.destinationID = "" }
                        showDestinations = false
                    }
                    if !project.destinationID.isEmpty && selected == nil {
                        Text("Saved device unavailable").foregroundStyle(.secondary)
                    }
                    Section("Devices") {
                        ForEach(store.destinations.filter { $0.kind == .device }) { device in
                            destinationMenuItem(device, project: project)
                        }
                    }
                    Section("Simulators") {
                        ForEach(store.destinations.filter { $0.kind == .simulator }) { device in
                            destinationMenuItem(device, project: project)
                        }
                    }
                }.listStyle(.inset)
                if let message = store.deviceMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        .help(message).padding(12)
                } else if store.destinations.isEmpty && !store.loadingDevices {
                    Text("No devices found. Connect and unlock your iPhone.")
                        .font(.caption).foregroundStyle(.secondary).padding(12)
                }
            }
            .frame(width: 340, height: 390)
            .task { await store.refreshDevices() }
        }
        .onChange(of: project.id) { _, _ in showDestinations = false }
    }

    private func destinationMenuItem(_ device: RunDestination, project: TrackedProject) -> some View {
        Button {
            store.update(project.id) { $0.destinationID = device.id }
            showDestinations = false
        } label: {
            HStack {

            if device.id == project.destinationID {
                Label(device.label + (device.kind == .simulator ? " · " + device.detail : ""), systemImage: "checkmark")
            } else { Text(device.label + (device.kind == .simulator ? " · " + device.detail : "")) }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func settings(_ project: TrackedProject) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("SCHEME").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    if store.discovering.contains(project.id) {
                        HStack { ProgressView().controlSize(.small); Text("Discovering schemes…").font(.callout) }
                    } else {
                        Picker("Scheme", selection: binding(project.id, \.scheme)) {
                            if project.schemes.isEmpty { Text("Refresh schemes to begin").tag("") }
                            ForEach(project.schemes, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 7) {
                    Text("CONFIGURATION").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Picker("Configuration", selection: binding(project.id, \.configuration)) {
                        ForEach(project.configurations, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                }.frame(width: 160)
            }
            if store.deviceMessage != nil || (store.destinations.isEmpty && !store.loadingDevices) {
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    if let message = store.deviceMessage {
                        DisclosureGroup("Device discovery needs attention") {
                            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }.font(.caption)
                    } else if store.destinations.isEmpty && !store.loadingDevices {
                        Text("Connect and trust your iPhone, enable Developer Mode, then open the destination list.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(20).background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .disabled(store.activeID == project.id || store.queue.contains(project.id))
    }

    private func runBar(_ project: TrackedProject) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        if store.activeID == project.id { ProgressView().controlSize(.small) }
                        Text(store.statuses[project.id] ?? "Ready to run").font(.headline)
                        if store.activeID == project.id, let start = store.startedAt {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(elapsed(context.date.timeIntervalSince(start))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let date = project.lastSuccess {
                        Text("Last successful run \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else { Text("No successful run yet").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            if let progress = store.buildProgress[project.id] {
                progressPanel(project, progress: progress)
            }
        }
    }

    private func progressPanel(_ project: TrackedProject, progress: BuildProgress) -> some View {
        let active = store.activeID == project.id
        let succeeded = ["Run succeeded", "Launched"].contains(store.statuses[project.id] ?? "")
        let phases: [RunPhase] = progress.launchOnly ? [.launching] : RunPhase.allCases
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ForEach(phases, id: \.rawValue) { phase in
                    let done = succeeded || phase.rawValue < progress.phase.rawValue
                    let current = phase == progress.phase
                    HStack(spacing: 6) {
                        Image(systemName: done ? "checkmark.circle.fill" : current && !active ? "exclamationmark.circle" : "circle")
                        Text(phase.label).font(.caption.weight(current ? .semibold : .regular))
                    }
                    .foregroundStyle(done ? Color.green : current ? Color.accentColor : Color.secondary)
                    if phase != phases.last { Rectangle().fill(.quaternary).frame(height: 1) }
                }
            }
            if active {
                ProgressView().progressViewStyle(.linear)
                Text(progress.activity).font(.callout).lineLimit(2).help(progress.activity)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if context.date.timeIntervalSince(progress.lastOutput) >= 10 {
                        Text("Waiting for tool output · \(elapsed(context.date.timeIntervalSince(progress.lastOutput))) since last update")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if progress.activities > 0 || progress.warnings > 0 || progress.errors > 0 {
                HStack(spacing: 16) {
                    Text("\(progress.activities) build activities")
                    Label("\(progress.warnings) warnings", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(progress.warnings > 0 ? Color.orange : Color.secondary)
                    Label("\(progress.errors) errors", systemImage: "xmark.octagon")
                        .foregroundStyle(progress.errors > 0 ? Color.red : Color.secondary)
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(16).background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        .accessibilityElement(children: .combine)
    }

    private func changeList(_ project: TrackedProject) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Changes since last run").font(.headline)
                Spacer()
                Button { store.scan(project.id) } label: { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).help("Rescan project files")
            }
            if let error = store.scanErrors[project.id] {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            } else if let changes = store.changes[project.id] {
                if changes.isEmpty {
                    Label("All caught up", systemImage: "checkmark.circle").foregroundStyle(.secondary).padding(.vertical, 8)
                } else {
                    DisclosureGroup("\(changes.count) files changed", isExpanded: $showChanges) {
                        VStack(spacing: 0) {
                            ForEach(changes.prefix(100)) { change in
                                HStack {
                                    Text(change.path).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(change.kind).font(.caption).foregroundStyle(change.kind == "Deleted" ? Color.red : Color.secondary)
                                }.padding(.vertical, 5)
                            }
                            if changes.count > 100 { Text("And \(changes.count - 100) more files").font(.caption).foregroundStyle(.secondary) }
                        }.padding(.top, 8).textSelection(.enabled)
                    }
                }
            } else { ProgressView("Reading project files…").controlSize(.small) }
            Text("Watching files. Runs start only when you press Run.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func outputPanel(_ project: TrackedProject) -> some View {
        ProjectOutputView(store: store, projectID: project.id)
    }

    private func binding(_ id: UUID, _ keyPath: WritableKeyPath<TrackedProject, String>) -> Binding<String> {
        Binding(get: { store.projects.first { $0.id == id }?[keyPath: keyPath] ?? "" },
                set: { value in
                    guard store.projects.first(where: { $0.id == id })?[keyPath: keyPath] != value else { return }
                    store.update(id) { $0[keyPath: keyPath] = value }
                })
    }
    private func sidebarStatus(_ project: TrackedProject) -> String {
        if let status = store.statuses[project.id] { return status }
        if store.scanErrors[project.id] != nil { return "Folder unavailable" }
        if project.baseline == nil { return "First run pending" }
        return store.changes[project.id]?.isEmpty == true ? "No changes" : "Changes pending"
    }
    private func elapsed(_ seconds: TimeInterval) -> String { "\(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))" }
}
