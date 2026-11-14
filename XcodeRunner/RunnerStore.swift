import SwiftUI
import AppKit
import Combine

@MainActor
final class RunnerStore: ObservableObject {
    @Published var projects: [TrackedProject] = []
    @Published var selection: UUID?
    @Published var destinations: [RunDestination] = []
    @Published var changes: [UUID: [FileChange]] = [:]
    @Published var scanErrors: [UUID: String] = [:]
    @Published var statuses: [UUID: String] = [:]
    @Published var logs: [UUID: String] = [:]
    @Published var consoles: [UUID: AppConsoleSession] = [:]
    @Published private(set) var menuAppStates: [UUID: AppExecutionState] = [:]
    @Published private(set) var lastFinishedID: UUID?
    private var consoleStateObservers: [UUID: AnyCancellable] = [:]
    private var launchingConsole: AppConsoleSession?
    @Published var activeID: UUID?
    @Published var startedAt: Date?
    @Published var waitingForUnlockID: UUID?
    @Published var queue: [UUID] = []
    @Published var loadingDevices = false
    @Published var discovering: Set<UUID> = []
    @Published var message: String?
    @Published var importing = false
    @Published var pendingImport: ProjectImportReview?
    @Published var importStatus: String?
    @Published var buildProgress: [UUID: BuildProgress] = [:]
    private var buildParser: BuildOutputParser?
    @Published var deviceMessage: String?
    private var watchers: [UUID: ProjectWatcher] = [:]
    private var scanTasks: [UUID: Task<Void, Never>] = [:]
    private var scanAgain: Set<UUID> = []
    private var command: CommandRunner?
    private var cancelRequested = false
    private let storage: URL

    init() {
        storage = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XcodeRunner/projects.json")
        if FileManager.default.fileExists(atPath: storage.path) {
            do { projects = try JSONDecoder().decode([TrackedProject].self, from: Data(contentsOf: storage)) }
            catch { message = "Could not read saved projects: \(error.localizedDescription)" }
        }
        selection = projects.first?.id
        for project in projects { watch(project); scan(project.id) }
        Task { await refreshDevices() }
    }

    var selected: TrackedProject? { projects.first { $0.id == selection } }
    var sortedProjects: [TrackedProject] {
        projects.sorted {
            let left = !(changes[$0.id] ?? []).isEmpty
            let right = !(changes[$1.id] ?? []).isEmpty
            return left != right ? left : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    func save() {
        do {
            try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(projects).write(to: storage, options: .atomic)
        } catch { message = "Could not save projects: \(error.localizedDescription)" }
    }
    func update(_ id: UUID, _ edit: (inout TrackedProject) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        edit(&projects[index]); save()
    }
    func addProject() {
        guard !importing else { return }
        let panel = NSOpenPanel()
        panel.title = "Add projects or a folder"
        panel.message = "Choose a folder to scan for Xcode projects, or select a single workspace/project. You can review multiple projects before importing."
        panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true; importStatus = "Finding Xcode projects…"
        Task {
            defer { if pendingImport == nil { importing = false } }
            do {
                let choices = try await Task.detached { try XcodeTools.discover(in: url) }.value
                guard !choices.isEmpty else { throw RunnerError.message("No Xcode projects or workspaces found below this folder.") }
                let folderImport = !["xcworkspace", "xcodeproj"].contains(url.pathExtension)
                let candidates = XcodeTools.containersToImport(choices,
                    saved: projects.map { URL(fileURLWithPath: $0.containerPath) }, folderImport: folderImport)
                let skipped = choices.count - candidates.count
                if choices.count > 1 && !candidates.isEmpty {
                    pendingImport = ProjectImportReview(candidates: candidates, alreadyAdded: skipped)
                    importStatus = "Choose projects to import"
                } else {
                    await importCandidates(candidates, alreadyAdded: skipped)
                }
            } catch { importStatus = "Import failed"; message = error.localizedDescription }
        }
    }
    func cancelImportReview() {
        guard pendingImport != nil else { return }
        pendingImport = nil
        importing = false
        importStatus = "Import cancelled"
    }
    func confirmImport(_ selectedPaths: Set<String>) {
        guard let review = pendingImport else { return }
        let chosen = review.candidates.filter { selectedPaths.contains($0.path) }
        guard !chosen.isEmpty else { return }
        pendingImport = nil
        Task {
            defer { importing = false }
            await importCandidates(chosen, alreadyAdded: review.alreadyAdded, excluded: review.candidates.count - chosen.count)
        }
    }
    private func importCandidates(_ candidates: [URL], alreadyAdded: Int, excluded: Int = 0) async {
        let added = candidates.map { add($0, discoverSchemes: false) }
        if let first = added.first { selection = first }
        for (index, id) in added.enumerated() {
            importStatus = "Loading schemes \(index + 1) of \(added.count)…"
            await refreshSchemes(id, reportErrors: false)
        }
        importStatus = "Imported \(added.count) project\(added.count == 1 ? "" : "s")"
            + (alreadyAdded > 0 ? " · \(alreadyAdded) already added" : "")
            + (excluded > 0 ? " · \(excluded) excluded" : "")
    }
    @discardableResult
    func add(_ url: URL, discoverSchemes: Bool = true) -> UUID {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = projects.first(where: { $0.containerPath == url.path }) { selection = existing.id; return existing.id }
        let project = TrackedProject(containerPath: url.path, rootPath: url.deletingLastPathComponent().path)
        projects.append(project); selection = project.id; save(); watch(project); scan(project.id)
        if discoverSchemes { Task { await refreshSchemes(project.id) } }
        return project.id
    }
    func removableProjectIDs(from ids: Set<UUID>) -> Set<UUID> {
        ids.intersection(projects.map(\.id)).filter { $0 != activeID && !queue.contains($0) }
    }
    func remove(_ id: UUID) { removeProjects([id]) }
    func removeProjects(_ ids: Set<UUID>) {
        let removable = removableProjectIDs(from: ids)
        guard !removable.isEmpty else { return }
        for id in removable {
            consoles[id]?.stop(); consoles[id] = nil
            consoleStateObservers[id] = nil; menuAppStates[id] = nil
            if lastFinishedID == id { lastFinishedID = nil }
            watchers[id] = nil; scanTasks[id]?.cancel(); scanTasks[id] = nil
            scanAgain.remove(id)
            changes[id] = nil; logs[id] = nil; scanErrors[id] = nil
            statuses[id] = nil; buildProgress[id] = nil
        }
        projects.removeAll { removable.contains($0.id) }
        if let selection, removable.contains(selection) { self.selection = projects.first?.id }
        save()
    }
    private func watch(_ project: TrackedProject) {
        watchers[project.id] = ProjectWatcher(root: project.rootPath) { [weak self] in
            self?.scan(project.id)
        }
    }
    func scan(_ id: UUID) {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        // No source comparison or file badges exist until a successful run.
        guard project.baseline != nil else { changes[id] = []; scanErrors[id] = nil; return }
        if scanTasks[id] != nil { scanAgain.insert(id); return }
        scanTasks[id] = Task {
            do {
                try await Task.sleep(for: .milliseconds(500))
                let snapshot = try await Task.detached { try SourceSnapshot.capture(root: project.rootPath) }.value
                guard !Task.isCancelled, let latest = projects.first(where: { $0.id == id }) else { return }
                changes[id] = SourceSnapshot.changes(current: snapshot, baseline: latest.baseline)
                scanErrors[id] = nil
            } catch { if !Task.isCancelled { scanErrors[id] = error.localizedDescription } }
            scanTasks[id] = nil
            if scanAgain.remove(id) != nil { scan(id) }
        }
    }
    func refreshSchemes(_ id: UUID, reportErrors: Bool = true) async {
        guard let project = projects.first(where: { $0.id == id }), !discovering.contains(id) else { return }
        discovering.insert(id)
        defer { discovering.remove(id) }
        do {
            let result = try await XcodeTools.schemes(for: project)
            guard projects.contains(where: { $0.id == id }) else { return }
            if statuses[id] == "Scheme discovery failed" { statuses[id] = nil }
            update(id) {
                $0.schemes = result.schemes; $0.configurations = result.configurations
                if !result.schemes.contains($0.scheme) { $0.scheme = result.schemes.first ?? "" }
                if !result.configurations.contains($0.configuration) { $0.configuration = result.configurations.first ?? "Debug" }
            }
        } catch {
            guard projects.contains(where: { $0.id == id }) else { return }
            statuses[id] = "Scheme discovery failed"
            append(error.localizedDescription + "\n", to: id)
            if reportErrors { message = error.localizedDescription }
        }
    }
    func refreshDevices() async {
        guard !loadingDevices else { return }
        loadingDevices = true; deviceMessage = nil
        defer { loadingDevices = false }
        var found: [RunDestination] = []
        var errors: [String] = []
        // Independent discovery failures do not hide the other destination type.
        async let physical = XcodeTools.devices()
        async let simulated = XcodeTools.simulators()
        do { found += try await physical } catch { errors.append("iPhone discovery: \(error.localizedDescription)") }
        do { found += try await simulated } catch { errors.append("Simulator discovery: \(error.localizedDescription)") }
        destinations = RunDestination.ordered(found)
        if !errors.isEmpty { deviceMessage = errors.joined(separator: "\n") }
    }
    func canRun(_ project: TrackedProject) -> Bool {
        !project.scheme.isEmpty && destinations.contains { $0.id == project.destinationID && $0.available }
            && activeID != project.id && !queue.contains(project.id) && !discovering.contains(project.id)
    }
    func canLaunch(_ project: TrackedProject) -> Bool {
        canRun(project) && project.lastBundleID != nil && project.lastRunSettings == project.settingsKey
            && project.baseline != nil && changes[project.id]?.isEmpty == true && scanErrors[project.id] == nil
    }
    func enqueue(_ id: UUID) {
        guard let project = projects.first(where: { $0.id == id }), canRun(project) else { return }
        queue.append(id); statuses[id] = "Queued"; next()
    }
    func unqueue(_ id: UUID) { queue.removeAll { $0 == id }; statuses[id] = "Removed from queue" }
    private func next() {
        guard activeID == nil, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        guard let project = projects.first(where: { $0.id == id }) else { next(); return }
        start(project, launchOnly: false)
    }
    func launchAgain(_ project: TrackedProject) {
        guard activeID == nil, canLaunch(project) else { return }
        start(project, launchOnly: true)
    }
    func shutdown() {
        queue.removeAll()
        stop()
        for console in consoles.values { console.stop() }
    }
    func stop() {
        cancelRequested = true
        if let activeID { statuses[activeID] = "Stopping…" }
        command?.cancel()
        launchingConsole?.stop()
    }
    private func append(_ text: String, to id: UUID) {
        logs[id, default: ""] += text
        if logs[id, default: ""].count > 250_000 { logs[id] = String(logs[id, default: ""].suffix(200_000)) }
    }
    private func start(_ project: TrackedProject, launchOnly: Bool) {
        activeID = project.id; startedAt = Date(); cancelRequested = false
        buildProgress[project.id] = BuildProgress(launchOnly: launchOnly)
        logs[project.id] = "\(project.name) · \(project.scheme) · \(project.configuration)\n\(Date().formatted())\n\n"
        let runner = CommandRunner(); command = runner
        Task {
            defer { activeID = nil; startedAt = nil; command = nil; buildParser = nil; launchingConsole = nil; waitingForUnlockID = nil; next() }
            do {
                guard let destination = destinations.first(where: { $0.id == project.destinationID && $0.available }) else {
                    throw RunnerError.message("Selected device is unavailable. Refresh destinations and reconnect it.")
                }
                var bundleID = project.lastBundleID ?? ""
                var baseline: [String: String]?
                if !launchOnly {
                    statuses[project.id] = "Reading changes"
                    baseline = try await Task.detached { try SourceSnapshot.capture(root: project.rootPath) }.value
                    try checkCancellation()
                    let derived = storage.deletingLastPathComponent().appendingPathComponent("DerivedData/\(project.id.uuidString)")
                    let arguments = project.containerArguments + ["-scheme", project.scheme, "-configuration", project.configuration,
                        "-destination", destination.kind == .device ? "generic/platform=iOS" : "platform=iOS Simulator,id=\(destination.id)",
                        "-derivedDataPath", derived.path]
                    statuses[project.id] = "Building"
                    setPhase(.building, activity: "Preparing build", id: project.id)
                    buildParser = BuildOutputParser()
                    _ = try await execute(runner, "/usr/bin/xcodebuild", arguments + ["build"], project: project, timeout: 3600, trackBuild: true)
                    try checkCancellation()
                    statuses[project.id] = "Locating app"
                    buildProgress[project.id]?.activity = "Locating the built application"
                    let settings = try await runner.run("/usr/bin/xcodebuild", arguments + ["-showBuildSettings", "-json"], directory: project.rootPath)
                    let product = try XcodeTools.appProduct(settingsText: settings)
                    bundleID = product.bundleID
                    guard FileManager.default.fileExists(atPath: product.path) else { throw RunnerError.message("Built app was not found: \(product.path)") }
                    try checkCancellation()
                    if destination.kind == .simulator { try await boot(destination, runner: runner, project: project) }
                    await disconnectConsoles(projectID: project.id, destination: destination, bundleID: bundleID)
                    try checkCancellation()
                    statuses[project.id] = "Installing"
                    setPhase(.installing, activity: "Installing on \(destination.name)", id: project.id)
                    let install = destination.kind == .device
                        ? ["devicectl", "device", "install", "app", "--device", destination.id, "--timeout", "120", product.path]
                        : ["simctl", "install", destination.id, product.path]
                    _ = try await withUnlockedDevice(destination, project: project, runner: runner, phase: .installing, status: "Installing") {
                        try await self.execute(runner, "/usr/bin/xcrun", install, project: project, timeout: 150)
                    }
                } else if destination.kind == .simulator { try await boot(destination, runner: runner, project: project) }
                try checkCancellation()
                statuses[project.id] = "Launching"
                setPhase(.launching, activity: "Opening on \(destination.name)", id: project.id)
                await disconnectConsoles(projectID: project.id, destination: destination, bundleID: bundleID)
                try checkCancellation()
                try await withUnlockedDevice(destination, project: project, runner: runner, phase: .launching, status: "Launching") {
                    let console = AppConsoleSession(destination: destination, bundleID: bundleID, runSettingsKey: project.settingsKey)
                    self.consoles[project.id] = console
                    self.observeConsoleState(console, projectID: project.id)
                    self.launchingConsole = console
                    console.start(directory: project.rootPath)
                    do { try await console.waitForLaunch() }
                    catch {
                        await console.stopAndWait()
                        self.launchingConsole = nil
                        throw error
                    }
                    self.launchingConsole = nil
                }
                try checkCancellation()
                if !launchOnly {
                    update(project.id) {
                        $0.baseline = baseline; $0.lastSuccess = Date(); $0.lastBundleID = bundleID
                        $0.lastDestinationID = destination.id; $0.lastRunSettings = project.settingsKey
                    }
                }
                statuses[project.id] = launchOnly ? "Launched" : "Run succeeded"
                lastFinishedID = project.id
                append("\n✓ \(launchOnly ? "Launch" : "Build, install, and launch") succeeded.\n", to: project.id)
                scan(project.id)
            } catch {
                launchingConsole?.stop()
                let cancelled = cancelRequested || error is CancellationError
                statuses[project.id] = cancelled ? "Cancelled" : "Failed"
                lastFinishedID = project.id
                append("\n\(cancelled ? "Cancelled. Changes remain pending." : error.localizedDescription)\n", to: project.id)
            }
        }
    }
    private func observeConsoleState(_ console: AppConsoleSession, projectID: UUID) {
        menuAppStates[projectID] = console.appState
        // Observe lifecycle only, never the high-frequency log text. Deliver after
        // the published fields settle and ignore callbacks from replaced sessions.
        consoleStateObservers[projectID] = Publishers.CombineLatest3(console.$status, console.$isRunning, console.$launched)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak console] _ in
                guard let self, let console, self.consoles[projectID]?.id == console.id else { return }
                if self.menuAppStates[projectID] != console.appState { self.menuAppStates[projectID] = console.appState }
            }
    }
    private func withUnlockedDevice<T>(_ destination: RunDestination, project: TrackedProject, runner: CommandRunner,
                                       phase: RunPhase, status: String, operation: () async throws -> T) async throws -> T {
        guard destination.kind == .device else { return try await operation() }
        defer { waitingForUnlockID = nil }
        return try await DeviceUnlockGate().perform(check: {
            try await DeviceLockState.query(destination: destination, runner: runner)
        }, checkCancellation: { try self.checkCancellation() }, waiting: { remaining in
            if self.waitingForUnlockID == nil { self.append("\nDevice locked. Waiting up to two minutes for unlock…\n", to: project.id) }
            self.waitingForUnlockID = project.id
            self.statuses[project.id] = "Waiting for device unlock"
            self.setPhase(phase, activity: "Unlock \(destination.name) to continue · \(remaining / 60):\(String(format: "%02d", remaining % 60)) remaining", id: project.id)
        }, resuming: {
            if self.waitingForUnlockID != nil { self.append("Device unlocked. Continuing \(status.lowercased())…\n", to: project.id) }
            self.waitingForUnlockID = nil
            self.statuses[project.id] = status
            self.setPhase(phase, activity: "\(status) on \(destination.name)", id: project.id)
        }, operation: operation)
    }
    private func disconnectConsoles(projectID: UUID, destination: RunDestination, bundleID: String) async {
        let previous = consoles.filter {
            $0.key == projectID || ($0.value.destination.id == destination.id && $0.value.bundleID == bundleID)
        }.map(\.value)
        for console in previous { await console.stopAndWait() }
    }
    private func checkCancellation() throws { if cancelRequested { throw CancellationError() } }
    private func setPhase(_ phase: RunPhase, activity: String, id: UUID) {
        buildProgress[id]?.phase = phase
        buildProgress[id]?.activity = activity
        buildProgress[id]?.lastOutput = Date()
    }
    private func execute(_ runner: CommandRunner, _ executable: String, _ arguments: [String], project: TrackedProject,
                         timeout: TimeInterval, trackBuild: Bool = false) async throws -> String {
        append("\n› \(URL(fileURLWithPath: executable).lastPathComponent) \(arguments.joined(separator: " "))\n", to: project.id)
        // Buffer output off the UI thread, then consume in command order. No late
        // callbacks may update the phase after the next command has started.
        let output = CommandOutputBuffer()
        let pump = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                receiveOutput(output.drain(), projectID: project.id, trackBuild: trackBuild)
            }
        }
        defer {
            pump.cancel()
            receiveOutput(output.drain(), projectID: project.id, trackBuild: trackBuild)
            if trackBuild {
                buildParser?.finish()
                if let progress = buildParser?.progress { buildProgress[project.id] = progress }
                buildParser = nil
            }
        }
        return try await runner.run(executable, arguments, directory: project.rootPath, timeout: timeout) { text in output.append(text) }
    }
    private func receiveOutput(_ text: String, projectID: UUID, trackBuild: Bool) {
        guard !text.isEmpty else { return }
        append(text, to: projectID)
        if trackBuild {
            buildParser?.consume(text)
            if let progress = buildParser?.progress { buildProgress[projectID] = progress }
        } else { buildProgress[projectID]?.lastOutput = Date() }
    }
    private func boot(_ destination: RunDestination, runner: CommandRunner, project: TrackedProject) async throws {
        statuses[project.id] = "Starting simulator"
        setPhase(buildProgress[project.id]?.launchOnly == true ? .launching : .installing,
                 activity: "Starting \(destination.name)", id: project.id)
        let response = try await runner.run("/usr/bin/xcrun", ["simctl", "list", "devices", "--json"])
        let groups = try XcodeTools.json(response)["devices"] as? [String: [[String: Any]]] ?? [:]
        let state = groups.values.flatMap { $0 }.first { $0["udid"] as? String == destination.id }?["state"] as? String
        if state != "Booted" {
            _ = try await execute(runner, "/usr/bin/xcrun", ["simctl", "boot", destination.id], project: project, timeout: 60)
        }
        _ = try await execute(runner, "/usr/bin/xcrun", ["simctl", "bootstatus", destination.id, "-b"], project: project, timeout: 180)
        _ = try await runner.run("/usr/bin/open", ["-a", "Simulator"])
    }
}
