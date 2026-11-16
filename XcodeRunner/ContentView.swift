import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var store: RunnerStore
    @State private var showChanges = true
    @State private var reviewVisible = false
    @State private var reviewChange: FileChange?
    @State private var showDestinations = false
    @State private var selectedProjectIDs: Set<UUID> = []

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let project = store.selected {
                HSplitView {
                    dashboard(project).frame(minWidth: 320)
                    if reviewVisible, let change = reviewChange {
                        GitReviewView(store: store, project: project, change: change) { reviewVisible = false }
                            .id("\(project.id)|\(change.path)")
                            .frame(minWidth: 360, idealWidth: 620, maxWidth: 1200)
                    }
                }
            } else { emptyState }
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
                    .fixedSize(horizontal: true, vertical: false)
                }
            }

        }
        .onChange(of: store.selection) { _, _ in reviewVisible = false; reviewChange = nil }
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
                            ProjectIconView(project: project)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(project.name).font(.system(.body, weight: .medium)).lineLimit(1)
                                Text(sidebarStatus(project)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            let count = store.changes[project.id]?.count ?? 0
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.triangle.branch")
                                Text("\(count)").monospacedDigit()
                            }
                            .font(.caption)
                            .frame(width: 48, alignment: .trailing)
                            .opacity(count > 0 ? 1 : 0)
                            .accessibilityHidden(count == 0)
                            .accessibilityLabel("\(count) uncommitted Git files")
                            .help("\(count) uncommitted Git files")
                            ProgressView().controlSize(.small)
                                .frame(width: 16, height: 16)
                                .opacity(store.activeID == project.id ? 1 : 0)
                                .accessibilityHidden(store.activeID != project.id)
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
        GeometryReader { geometry in
         VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        header(project)
                        settings(project)
                    }
                    runBar(project)
                    changeList(project)
                }.padding(20)
            }
            ProjectOutputView(store: store, projectID: project.id,
                maximumContentHeight: max(120, geometry.size.height - 230))
         }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .id(project.id)
    }

    private func header(_ project: TrackedProject) -> some View {
        HStack(spacing: 12) {
            Text(project.name).font(.headline).lineLimit(1)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.containerPath)])
            } label: {
                Label(project.rootPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"), systemImage: "folder")
                    .font(.caption).lineLimit(1).truncationMode(.middle)
            }.buttonStyle(.plain).foregroundStyle(.secondary).help("Show in Finder: " + project.rootPath)
            Spacer(minLength: 0)
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
                    .help("Cancel the current build, archive, or launch")
            } else if store.queue.contains(project.id) {
                Button("Unqueue", systemImage: "xmark") { store.unqueue(project.id) }
            } else {
                Button(store.activeID == nil ? "Run" : "Queue Run", systemImage: "play.fill") {
                    store.enqueue(project.id)
                }
                .disabled(!store.canRun(project))
                .help("Build, install, and launch the selected scheme")
                RunActionsMenu(store: store, project: project)
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
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    schemePicker(project).fixedSize(horizontal: true, vertical: false)
                    configurationPicker(project)
                    Spacer(minLength: 0)
                    ProjectVersionView(project: project).fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 12) {
                        schemePicker(project)
                        configurationPicker(project)
                        Spacer(minLength: 0)
                    }
                    ProjectVersionView(project: project)
                }
            }.controlSize(.small)
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
        .disabled(store.activeID == project.id || store.queue.contains(project.id))
    }

    private func schemePicker(_ project: TrackedProject) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if store.discovering.contains(project.id) {
                HStack { ProgressView().controlSize(.small); Text("Discovering schemes…").font(.callout) }
            } else {
                Picker("Scheme", selection: binding(project, \.scheme)) {
                    Text("Choose an app scheme").tag("")
                    if !project.scheme.isEmpty && !project.schemes.contains(project.scheme) {
                        Text("\(project.scheme) · Unavailable").tag(project.scheme)
                    }
                    ForEach(pickerOptions(project.schemes), id: \.self) { name in
                        Text(name + (store.recommendedSchemes[project.id] == name ? " · Suggested" : "")).tag(name)
                    }
                }.labelsHidden()
            }
            if let suggested = store.recommendedSchemes[project.id], suggested != project.scheme {
                Button("Use suggested: \(suggested)") { store.update(project.id) { $0.scheme = suggested } }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
            }
        }.frame(minWidth: 120, idealWidth: 200, maxWidth: 200, alignment: .leading)
    }

    private func configurationPicker(_ project: TrackedProject) -> some View {
        Picker("Configuration", selection: binding(project, \.configuration)) {
            Text("Choose configuration").tag("")
            if !project.configuration.isEmpty && !project.configurations.contains(project.configuration) {
                Text("\(project.configuration) · Unavailable").tag(project.configuration)
            }
            ForEach(pickerOptions(project.configurations), id: \.self) { Text($0).tag($0) }
        }.labelsHidden().frame(width: 110)
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
        let succeeded = ["Run succeeded", "Launched", "Archive succeeded"].contains(store.statuses[project.id] ?? "")
        let phases: [RunPhase] = progress.archiving ? [.building] : progress.launchOnly ? [.launching] : RunPhase.allCases
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ForEach(phases, id: \.rawValue) { phase in
                    let done = succeeded || phase.rawValue < progress.phase.rawValue
                    let current = phase == progress.phase
                    HStack(spacing: 6) {
                        Image(systemName: done ? "checkmark.circle.fill" : current && !active ? "exclamationmark.circle" : "circle")
                        Text(progress.archiving ? "Archive" : phase.label).font(.caption.weight(current ? .semibold : .regular))
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
                    Button { store.showIssues(project.id, filter: .warnings) } label: {
                        Label("\(progress.warnings) warnings", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(progress.warnings > 0 ? Color.orange : Color.secondary)
                    }.buttonStyle(.plain).help("Show build warnings")
                    Button { store.showIssues(project.id, filter: .errors) } label: {
                        Label("\(progress.errors) errors", systemImage: "xmark.octagon")
                            .foregroundStyle(progress.errors > 0 ? Color.red : Color.secondary)
                    }.buttonStyle(.plain).help("Show run errors")
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
                Text("Git changes").font(.headline)
                Spacer()
                Button { store.scan(project.id) } label: { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).help("Refresh Git status")
            }
            if let error = store.scanErrors[project.id] {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            } else if let changes = store.changes[project.id] {
                if changes.isEmpty {
                    Label("Working tree clean", systemImage: "checkmark.circle").foregroundStyle(.secondary).padding(.vertical, 8)
                } else {
                    DisclosureGroup("\(changes.count) files changed", isExpanded: $showChanges) {
                        LazyVStack(spacing: 0) {
                            ForEach(changes) { change in
                                Button {
                                    reviewChange = change; reviewVisible = true
                                } label: {
                                    HStack {
                                        Text(change.displayPath).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        Text(change.detail).font(.caption).lineLimit(1).layoutPriority(-1)
                                            .foregroundStyle(change.kind == "Deleted" || change.kind == "Conflict" ? Color.red : Color.secondary)
                                        changeEditTime(change)
                                        changeLineCounts(change)
                                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 6).padding(.vertical, 7)
                                    .contentShape(Rectangle())
                                    .background(reviewVisible && reviewChange?.path == change.path ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                                }.buttonStyle(.plain).help("Review changes in \(change.path)")
                            }
                        }.padding(.top, 8)
                    }
                }
            } else { ProgressView("Reading Git status…").controlSize(.small) }
            Text("Uncommitted Git changes · Staged, unstaged, and untracked · Repository-relative paths")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func changeEditTime(_ change: FileChange) -> some View {
        Group {
            if let date = change.lastModified {
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Text(date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
                }
                .help("Working file edited " + date.formatted(date: .complete, time: .complete))
                .accessibilityLabel("File edited " + date.formatted(date: .abbreviated, time: .standard))
            } else {
                Text("—").help("Edit time unavailable: the working file is deleted or inaccessible")
            }
        }
        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        .frame(width: 94, alignment: .trailing)
    }

    private func changeLineCounts(_ change: FileChange) -> some View {
        Group {
            if let stats = change.lineStats {
                if stats.binary { Text("Binary").foregroundStyle(.secondary) }
                else {
                    HStack(spacing: 8) {
                        Text("+\(stats.additions ?? 0)").foregroundStyle(.green).frame(width: 40, alignment: .trailing)
                        Text("−\(stats.deletions ?? 0)").foregroundStyle(.red).frame(width: 40, alignment: .trailing)
                    }.help("Added and deleted lines compared with HEAD")
                }
            } else { Text("—").foregroundStyle(.secondary).help("Line counts unavailable for this file") }
        }
        .font(.caption.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        .frame(width: 88, alignment: .trailing)
    }

    private func pickerOptions(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func binding(_ project: TrackedProject, _ keyPath: WritableKeyPath<TrackedProject, String>) -> Binding<String> {
        // Selection and tags use the same render snapshot. A live-store getter
        // could return an empty/new value while old rows are being reconciled.
        Binding(get: { project[keyPath: keyPath] }, set: { value in
            guard let current = store.projects.first(where: { $0.id == project.id }), current[keyPath: keyPath] != value else { return }
            store.update(project.id) { $0[keyPath: keyPath] = value }
        })
    }
    private func sidebarStatus(_ project: TrackedProject) -> String {
        if let status = store.statuses[project.id] { return status }
        if store.scanErrors[project.id] != nil { return "Git status unavailable" }
        guard let changes = store.changes[project.id] else { return "Reading Git status…" }
        return changes.isEmpty ? "Working tree clean" : "Uncommitted changes"
    }
    private func elapsed(_ seconds: TimeInterval) -> String { "\(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))" }
}
