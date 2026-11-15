import Foundation

@main
struct RegressionChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw RunnerError.message("FAIL: " + message) }
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("XcodeRunner-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("App.swift")
        try Data("first".utf8).write(to: source)
        for directory in [".git", "build", "DerivedData", "xcuserdata"] {
            let ignored = root.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
            try Data("noise".utf8).write(to: ignored.appendingPathComponent("noise"))
        }
        let baseline = try SourceSnapshot.capture(root: root.path)
        try require(baseline.count == 1, "Generated files are ignored")
        try require(SourceSnapshot.changes(current: baseline, baseline: nil).isEmpty, "Never-run projects have no file list or badges")
        try require(SourceSnapshot.changes(current: baseline, baseline: baseline).isEmpty, "Successful baseline is clean")
        // Same-length edits must be detected, regardless of modification date granularity.
        try Data("other".utf8).write(to: source)
        try Data("new".utf8).write(to: root.appendingPathComponent("New.swift"))
        let edited = try SourceSnapshot.capture(root: root.path)
        let changes = SourceSnapshot.changes(current: edited, baseline: baseline)
        try require(changes.map(\.kind) == ["Modified", "Added"], "Edits made after run snapshot stay pending")
        try FileManager.default.removeItem(at: source)
        let deleted = try SourceSnapshot.capture(root: root.path)
        try require(SourceSnapshot.changes(current: deleted, baseline: baseline).contains { $0.path == "App.swift" && $0.kind == "Deleted" }, "Deleted files stay visible")
        let original = TrackedProject(containerPath: root.appendingPathComponent("Demo.xcodeproj").path, rootPath: root.path, baseline: baseline)
        let restored = try JSONDecoder().decode(TrackedProject.self, from: JSONEncoder().encode(original))
        try require(restored.baseline == baseline && restored.id == original.id, "Baselines survive restart")

        let modern = Data(#"{"result":{"devices":[{"identifier":"phone","properties":{"state":{"name":"Test Phone"},"hardware":{"platform":"iOS","reality":"physical"},"connection":{"state":"disconnected","pairingState":"paired"}}},{"identifier":"sim","properties":{"state":{"name":"Simulator"},"hardware":{"platform":"iOS","reality":"simulated"},"connection":{"pairingState":"paired"}}}]}}"#.utf8)
        let devices = try XcodeTools.parseDevices(modern)
        try require(devices.count == 1 && devices[0].name == "Test Phone" && devices[0].available, "Modern device names, on-demand pairing, and simulator exclusion")
        let legacy = Data(#"{"result":{"devices":[{"identifier":"phone","deviceProperties":{"name":"Older Phone"},"hardwareProperties":{"platform":"iOS","reality":"physical"},"connectionProperties":{"tunnelState":"connected"}}]}}"#.utf8)
        let olderDevices = try XcodeTools.parseDevices(legacy)
        try require(olderDevices.first?.name == "Older Phone", "Legacy device response")
        let app = #"[{"buildSettings":{"WRAPPER_EXTENSION":"app","PRODUCT_TYPE":"com.apple.product-type.application","TARGET_BUILD_DIR":"/tmp/Products With Spaces","FULL_PRODUCT_NAME":"Example App.app","PRODUCT_BUNDLE_IDENTIFIER":"example.app"}},{"buildSettings":{"WRAPPER_EXTENSION":"appex","PRODUCT_TYPE":"com.apple.product-type.app-extension"}}]"#
        let product = try XcodeTools.appProduct(settingsText: app)
        try require(product.path == "/tmp/Products With Spaces/Example App.app", "App selection excludes extensions and preserves spaces")
        let noisyProduct = try XcodeTools.appProduct(settingsText: "2026-11-13 [MT] Supported platforms warning\n" + app + "\nwarning: trailing [diagnostic]\n")
        try require(noisyProduct.path == product.path, "ChanLurker-style bracketed diagnostics cannot corrupt build-settings JSON")
        let jsonNoise = try XcodeTools.json(#"warning: invalid { prefix {"devices":{"name":"literal ] bracket"}} [MT] trailing"#, containing: "devices")
        try require(jsonNoise["devices"] != nil, "Balanced JSON extraction ignores unmatched diagnostics and quoted brackets")
        // Recursive import: distinct roots, workspace preference, references, and ignored trees.
        let imports = root.appendingPathComponent("Import Fixtures")
        func container(_ path: String) throws -> URL {
            let url = imports.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let standalone = try container("Deep/More/App/Standalone.xcodeproj")
        _ = try container("Deep/More/App/Standalone.xcodeproj/project.xcworkspace")
        let other = try container("Other/Standalone.xcodeproj")
        _ = try container("Paired/Demo.xcodeproj")
        let workspace = try container("Paired/Demo.xcworkspace")
        try Data(#"<Workspace><FileRef location="group:Demo.xcodeproj"/></Workspace>"#.utf8)
            .write(to: workspace.appendingPathComponent("contents.xcworkspacedata"))
        let independent = try container("Paired/Independent.xcodeproj")
        let suite = try container("Suite/Combined.xcworkspace")
        _ = try container("Suite/Apps/Member.xcodeproj")
        try Data(#"<Workspace><Group location="group:Apps"><FileRef location="group:Member.xcodeproj"/></Group></Workspace>"#.utf8)
            .write(to: suite.appendingPathComponent("contents.xcworkspacedata"))
        for ignored in ["Pods", "Carthage", "node_modules", "DerivedData", "build", ".hidden"] {
            _ = try container("Ignored/\(ignored)/Dependency.xcodeproj")
        }
        try FileManager.default.createSymbolicLink(at: imports.appendingPathComponent("Linked"), withDestinationURL: imports.appendingPathComponent("Deep"))
        let found = try XcodeTools.discover(in: imports)
        let expected = [standalone, other, workspace, independent, suite].map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        try require(Set(found.map(\.path)) == Set(expected), "Recursive import prefers workspaces, preserves unrelated projects, and skips dependencies, symlinks, and embedded workspaces")
        let duplicate = try container("Paired/Alternate.xcworkspace")
        try Data(#"<Workspace><FileRef location="group:Demo.xcodeproj"/></Workspace>"#.utf8)
            .write(to: duplicate.appendingPathComponent("contents.xcworkspacedata"))
        let equivalentSaved = XcodeTools.containersToImport([workspace], saved: [duplicate], folderImport: true)
        try require(equivalentSaved.isEmpty, "An equivalent saved workspace is not imported under another name")
        let empty = try container("Empty/Orphan.xcworkspace")
        try Data("<Workspace/>".utf8).write(to: empty.appendingPathComponent("contents.xcworkspacedata"))
        let validProject = try container("Empty/Valid.xcodeproj")
        let misleading = try container("Empty/Valid.xcworkspace")
        try Data("<Workspace/>".utf8).write(to: misleading.appendingPathComponent("contents.xcworkspacedata"))
        let nested = try container("Nested/Wrapper.xcworkspace")
        try Data(#"<Workspace><FileRef location="group:../Paired/Demo.xcworkspace"/></Workspace>"#.utf8)
            .write(to: nested.appendingPathComponent("contents.xcworkspacedata"))
        let deduplicated = try XcodeTools.discover(in: imports)
        try require(!deduplicated.contains(duplicate.standardizedFileURL.resolvingSymlinksInPath()) && !deduplicated.contains(nested.standardizedFileURL.resolvingSymlinksInPath()), "Equivalent and nested workspaces collapse to the matching app workspace")
        try require(!deduplicated.contains(empty.standardizedFileURL.resolvingSymlinksInPath()) && deduplicated.contains(validProject.standardizedFileURL.resolvingSymlinksInPath()), "Empty workspaces are skipped and cannot suppress real projects")
        let cycle = try container("Cycle/Loop.xcworkspace")
        try Data(#"<Workspace><FileRef location="group:Loop.xcworkspace"/></Workspace>"#.utf8)
            .write(to: cycle.appendingPathComponent("contents.xcworkspacedata"))
        try require(XcodeTools.workspaceProjects(cycle).isEmpty, "Workspace cycles terminate safely")
        let direct = try XcodeTools.discover(in: standalone)
        try require(direct.count == 1 && direct[0].lastPathComponent == "Standalone.xcodeproj", "Direct project selection still works")
        let repeated = try XcodeTools.discover(in: imports)
        try require(repeated == deduplicated, "Folder discovery is stable on re-import")

        let reimport = XcodeTools.containersToImport(found, saved: found, folderImport: true)
        try require(reimport.isEmpty, "Re-import does not duplicate saved projects")
        let preserve = XcodeTools.containersToImport(found, saved: [workspace.deletingPathExtension().appendingPathExtension("xcodeproj")], folderImport: true)
        try require(!preserve.contains(workspace.standardizedFileURL.resolvingSymlinksInPath()), "An existing project keeps its settings when a sibling workspace is discovered")
        let projectBundle = workspace.deletingPathExtension().appendingPathExtension("xcodeproj")
        try Data(#"{objects={APP={isa=PBXNativeTarget;name="Demo";productType="com.apple.product-type.application";};LIB={isa=PBXNativeTarget;name="ActiveLabel";productType="com.apple.product-type.framework";};};}"#.utf8)
            .write(to: projectBundle.appendingPathComponent("project.pbxproj"))
        let demoProject = TrackedProject(containerPath: workspace.path, rootPath: workspace.deletingLastPathComponent().path)
        let suggestion = SchemeRecommendation.choose(schemes: ["ActiveLabel", "Demo", "Pods-Demo"], project: demoProject)
        try require(suggestion == "Demo", "App target wins over alphabetically earlier dependency schemes")
        let sharedSchemes = workspace.appendingPathComponent("xcshareddata/xcschemes")
        try FileManager.default.createDirectory(at: sharedSchemes, withIntermediateDirectories: true)
        try Data(#"<Scheme><LaunchAction><BuildableProductRunnable><BuildableReference BuildableName="Demo.app"/></BuildableProductRunnable></LaunchAction></Scheme>"#.utf8)
            .write(to: sharedSchemes.appendingPathComponent("Custom Run.xcscheme"))
        let custom = SchemeRecommendation.choose(schemes: ["ActiveLabel", "Custom Run"], project: demoProject)
        try require(custom == "Custom Run", "Custom app launch scheme is detected from its launch action")
        try require(SchemeRecommendation.choose(schemes: ["ActiveLabel", "Pods-Demo"], project: demoProject) == nil, "Unknown/library-only schemes do not receive an arbitrary app recommendation")
        let sourceFiles = try SourceSnapshot.capture(root: imports.path)
        try require(sourceFiles["Suite/Combined.xcworkspace/contents.xcworkspacedata"] != nil, "A symlink does not hide neighboring directories from source tracking")

        var parser = BuildOutputParser()
        parser.consume("SwiftCom")
        try require(parser.progress.activities == 0, "Partial output waits for a whole line")
        parser.consume("pile normal arm64 /tmp/Some App/Screen.swift (in target 'App' from project 'App')\n")
        try require(parser.progress.activities == 1 && parser.progress.activity.contains("Screen.swift"), "Compilation shows source and target")
        parser.consume("/tmp/Screen.swift:2: warning: sample warning\nLd /tmp/Example.app/Example normal (in target 'App' from project 'App')\n")
        try require(parser.progress.warnings == 1 && parser.progress.activities == 2 && parser.progress.activity.hasPrefix("Linking"), "Warnings and linking progress")
        parser.consume("CodeSign /tmp/Example.app\r\n")
        try require(parser.progress.activities == 3, "CRLF output is parsed")
        parser.consume("error: final diagnostic")
        parser.finish()
        try require(parser.progress.errors == 1, "Unterminated final error is counted")
        var fresh = BuildOutputParser()
        fresh.consume("Resolve Package Graph\nCodeSign /tmp/Example.app (in target 'App' from project 'App')\n")
        try require(fresh.progress.errors == 0 && fresh.progress.activities == 2 && fresh.progress.activity.hasPrefix("Signing"), "New run resets counters and tracks packages/signing")

        var deviceAck = ConsoleLaunchAcknowledgement(kind: .device, bundleID: "example.app")
        deviceAck.consume("Acquired tunnel connection\nLaunched application with example.app\n")
        try require(!deviceAck.launched, "Device launch waits for console attachment")
        deviceAck.consume("Waiting for the appli")
        deviceAck.consume("cation to terminate\r\n")
        try require(deviceAck.launched, "Chunked device console confirmation")
        var simAck = ConsoleLaunchAcknowledgement(kind: .simulator, bundleID: "example.app")
        simAck.consume("other.app: 123\nexample.app: 456\n")
        try require(simAck.launched, "Simulator PID confirms the selected app")
        var falseAck = ConsoleLaunchAcknowledgement(kind: .simulator, bundleID: "example.app")
        falseAck.consume("other.app: 123\nexample.app: error\n")
        try require(!falseAck.launched, "Unrelated simulator output cannot confirm launch")
        let phone = RunDestination(id: "test", name: "Test Phone", kind: .device, available: true, detail: "")
        let orderedDevices = RunDestination.ordered([
            RunDestination(id: "sim", name: "A Simulator", kind: .simulator, available: true, detail: ""),
            RunDestination(id: "off", name: "A Offline Phone", kind: .device, available: false, detail: ""),
            RunDestination(id: "phone", name: "Z Phone", kind: .device, available: true, detail: "")
        ])
        try require(orderedDevices.map(\.id) == ["phone", "off", "sim"], "Real devices precede simulators, with available devices first")
        let deviceCommand = ConsoleLaunchCommand.make(destination: phone, bundleID: "example.app")
        try require(deviceCommand.arguments.contains("--console") && deviceCommand.arguments.contains("{\"OS_ACTIVITY_DT_MODE\":\"enable\"}"), "Device launch enables console and framework logging")
        var decoder = UTF8OutputDecoder()
        let unicode = "SwiftUI 🐱 日本語\n"
        var decoded = ""
        for byte in unicode.utf8 { decoded += decoder.consume(Data([byte])) }
        decoded += decoder.finish()
        try require(decoded == unicode, "Log chunks preserve split multibyte characters")
        try require(ConsoleText.filtered("First warning\nSecond ERROR\n", query: "error") == "Second ERROR", "Console search filters without case sensitivity")
        let terminal = try await CommandRunner().run("/bin/sh", ["-c", "test -t 0 && test -t 1 && test -t 2 && printf 'terminal ready\n'"], usePTY: true)
        try require(terminal.contains("terminal ready"), "Console subprocess has a real terminal and reaches EOF")
        try await testConsoleSessions(phone: phone, directory: root.path)
        try await testUnlockGate()

        let locatedWarning = BuildDiagnostic.parse("/tmp/Project With Spaces/Screen.swift:42:7: warning: unused value")
        try require(locatedWarning?.severity == .warning && locatedWarning?.line == 42 && locatedWarning?.column == 7 && locatedWarning?.file == "/tmp/Project With Spaces/Screen.swift", "Compiler diagnostics retain file paths with spaces and exact line/column")
        let relativeError = BuildDiagnostic.parse("Sources/App.swift:12: error: unresolved name")
        try require(relativeError?.sourceURL(root: "/tmp/Demo")?.path == "/tmp/Demo/Sources/App.swift", "Relative diagnostic paths resolve against project root")
        let signing = BuildDiagnostic.parse("/tmp/Demo.xcodeproj: error: Signing requires a development team")
        try require(signing?.file == "/tmp/Demo.xcodeproj" && signing?.line == nil && signing?.severity == .error, "Project-level signing errors retain a clickable project location")
        let linker = BuildDiagnostic.parse("ld: warning: ignoring duplicate libraries")
        try require(linker?.file == nil && linker?.severity == .warning, "Location-free linker diagnostics remain visible")
        try require(BuildDiagnostic.parse("12 | print(\"error: application message\")") == nil, "Compiler source excerpts do not create false diagnostics")
        var issuesParser = BuildOutputParser()
        issuesParser.consume("/tmp/Demo.swift:8:")
        issuesParser.consume("3: warning: sample\n/tmp/Demo.swift:8:3: warning: sample\n/tmp/Demo.swift:9:3: error: failed")
        issuesParser.finish()
        issuesParser.finish()
        try require(issuesParser.diagnostics.count == 2 && issuesParser.progress.warnings == 1 && issuesParser.progress.errors == 1, "Chunked and unterminated diagnostics are deduplicated, with matching issue counts")

        let appendUpdate = ConsoleTextUpdate.between("old\n", and: "old\nnew 🐱\n")
        try require(!appendUpdate.replacesAll && appendUpdate.removedPrefix == 0 && appendUpdate.appended == "new 🐱\n", "Live output appends without rebuilding existing text")
        let retained = String(repeating: "retained 🐱 line\n", count: 100)
        let trimUpdate = ConsoleTextUpdate.between("expired\n" + retained, and: retained + "latest\n")
        try require(!trimUpdate.replacesAll && trimUpdate.removedPrefix == ("expired\n" as NSString).length && trimUpdate.appended == "latest\n", "Bounded log buffers trim only their expired prefix")
        let clearedUpdate = ConsoleTextUpdate.between("old\n", and: "")
        try require(clearedUpdate.removedPrefix == 4 && clearedUpdate.appended.isEmpty, "Clearing removes native text storage")
        for (old, next) in [("", "initial"), ("emoji 🐱", "emoji 🐱 more"), ("same", "same"),
                            ("warning\nerror\n", "error\n"), ("expired\n" + retained, retained + "new\n"), ("old", "")] {
            let edit = ConsoleTextUpdate.between(old, and: next)
            let storage = NSMutableString(string: old)
            storage.deleteCharacters(in: NSRange(location: 0, length: edit.removedPrefix))
            storage.append(edit.appended)
            try require(storage as String == next, "Native console edits preserve exact text and Unicode")
        }

        let runner = CommandRunner()
        let echo = try await runner.run("/usr/bin/printf", ["%s", "literal $(not-a-shell) with spaces"])
        try require(echo == "literal $(not-a-shell) with spaces", "Commands do not invoke a shell")
        let separated = try await CommandRunner().run("/bin/sh", ["-c", #"printf '{"ok":true}'; /usr/bin/awk 'BEGIN {for (i=0;i<10000;i++) print "diagnostic [MT]"}' >&2"#], mergeStandardError: false)
        try require(separated == #"{"ok":true}"#, "JSON commands keep stdout clean while draining large stderr output")
        let cancelled = CommandRunner()
        let task = Task { try await cancelled.run("/bin/sleep", ["20"]) }
        try await Task.sleep(for: .milliseconds(200))
        cancelled.cancel()
        do { _ = try await task.value; throw RunnerError.message("FAIL: Cancel must throw") }
        catch is CancellationError { }
        let beforeStart = CommandRunner(); beforeStart.cancel()
        do { _ = try await beforeStart.run("/usr/bin/true", []); throw RunnerError.message("FAIL: Cancel between stages must prevent launch") }
        catch is CancellationError { }
        print("PASS: snapshots, persistence, devices, products, recursive import, streamed build progress, live console lifecycle, unlock wait/retry/timeout, UTF-8, literal arguments, and cancellation")
    }
    @MainActor
    static func testConsoleSessions(phone: RunDestination, directory: String) async throws {
        let command = ConsoleLaunchCommand(executable: "/bin/sh", arguments: ["-c",
            "printf 'Waiting for the application to terminate\n'; sleep 0.2; printf 'SwiftUI sample warning\n'; sleep 10"], environment: [:])
        let console = AppConsoleSession(destination: phone, bundleID: "example.app", launchCommand: command)
        try require(console.appState == .unknown, "No console means unknown app state")
        console.start(directory: directory)
        try require(console.appState == .starting, "Unconfirmed launch has a starting indicator")
        try await console.waitForLaunch(timeout: .seconds(3))
        try require(console.appState == .running, "Confirmed live console shows a running indicator")
        try require(console.isRunning && console.launched, "Launch completes while the console remains live for queued runs")
        try await Task.sleep(for: .milliseconds(400))
        try require(console.text.contains("SwiftUI sample warning"), "App output continues after launch confirmation")
        console.clear()
        try require(console.text.isEmpty, "Clear removes retained output")
        await console.stopAndWait()
        try require(console.appState == .unknown, "Disconnect must not falsely report that the app exited")
        try require(!console.isRunning && console.status == "Disconnected", "Console disconnect cleans up the long-lived process")
        let exiting = AppConsoleSession(destination: phone, bundleID: "example.app",
            launchCommand: ConsoleLaunchCommand(executable: "/bin/sh", arguments: ["-c",
                "printf 'Waiting for the application to terminate\n'; sleep 0.2"], environment: [:]))
        exiting.start(directory: directory)
        try await exiting.waitForLaunch(timeout: .seconds(3))
        let exitDeadline = ContinuousClock.now + .seconds(3)
        while exiting.isRunning && ContinuousClock.now < exitDeadline { try await Task.sleep(for: .milliseconds(50)) }
        try require(exiting.appState == .exited, "Normal app exit updates the indicator to exited")
        let failed = AppConsoleSession(destination: phone, bundleID: "example.app",
            launchCommand: ConsoleLaunchCommand(executable: "/usr/bin/false", arguments: [], environment: [:]))
        failed.start(directory: directory)
        do { try await failed.waitForLaunch(timeout: .seconds(3)); throw RunnerError.message("FAIL: Failed console launch must not advance baseline") }
        catch let error as RunnerError {
            if error.localizedDescription.hasPrefix("FAIL:") { throw error }
        }
        try require(failed.appState == .unknown, "Connection failures do not assert app exit")
        try require(!failed.launched && !failed.isRunning, "Failed launcher does not report success")
        let quiet = AppConsoleSession(destination: phone, bundleID: "example.app",
            launchCommand: ConsoleLaunchCommand(executable: "/bin/sleep", arguments: ["10"], environment: [:]))
        quiet.start(directory: directory)
        do { try await quiet.waitForLaunch(timeout: .milliseconds(200)); throw RunnerError.message("FAIL: Silent launcher must time out") }
        catch let error as RunnerError {
            if error.localizedDescription.hasPrefix("FAIL:") { throw error }
        }
        await quiet.stopAndWait()
        try require(!quiet.isRunning && !quiet.launched, "Unconfirmed launch times out and cleans up")
    }

    @MainActor
    static func testUnlockGate() async throws {
        let locked = try DeviceLockState.parse(Data(#"{"result":{"passcodeRequired":true,"unlockedSinceBoot":true}}"#.utf8))
        let unlocked = try DeviceLockState.parse(Data(#"{"result":{"passcodeRequired":false,"unlockedSinceBoot":true}}"#.utf8))
        let firstUnlock = try DeviceLockState.parse(Data(#"{"result":{"unlockedSinceBoot":false}}"#.utf8))
        let unknown = try DeviceLockState.parse(Data(#"{"result":{}}"#.utf8))
        try require(locked == .locked && unlocked == .unlocked && firstUnlock == .locked && unknown == .unknown, "Explicit lock-state fields and first-unlock state")
        let gate = DeviceUnlockGate(timeout: .milliseconds(100), pollInterval: .milliseconds(5))
        var probes = 0
        var operations = 0
        var waits = 0
        let value = try await gate.perform(check: {
            probes += 1
            if probes == 2 { throw RunnerError.message("Temporary connection issue") }
            return probes < 4 ? .locked : .unlocked
        }, checkCancellation: {}, waiting: { _ in waits += 1 }, resuming: {}, operation: { operations += 1; return 42 })
        try require(value == 42 && operations == 1 && waits == 3, "Wait through lock and transient query failure, then resume exactly once")
        operations = 0
        _ = try await gate.perform(check: { .unlocked }, checkCancellation: {}, waiting: { _ in }, resuming: {}, operation: {
            operations += 1
            if operations == 1 { throw RunnerError.message("The device is locked.") }
            return 1
        })
        try require(operations == 2, "Lock between preflight and deployment retries after unlock confirmation")
        operations = 0
        do {
            _ = try await gate.perform(check: { .unlocked }, checkCancellation: {}, waiting: { _ in }, resuming: {}, operation: {
                operations += 1
                throw RunnerError.message("Provisioning profile missing")
            })
            throw RunnerError.message("FAIL: Non-lock failure must propagate")
        } catch let error as RunnerError { if error.localizedDescription.hasPrefix("FAIL:") { throw error } }
        try require(operations == 1, "Signing and unrelated failures are not retried")
        var cancelled = false
        operations = 0
        do {
            _ = try await gate.perform(check: { .locked }, checkCancellation: { if cancelled { throw CancellationError() } },
                waiting: { _ in cancelled = true }, resuming: {}, operation: { operations += 1; return 1 })
            throw RunnerError.message("FAIL: Stop must cancel unlock wait")
        } catch is CancellationError { }
        try require(operations == 0, "Cancellation while locked never deploys")
        do {
            _ = try await gate.perform(check: { .locked }, checkCancellation: {}, waiting: { _ in }, resuming: {}, operation: { operations += 1; return 1 })
            throw RunnerError.message("FAIL: Persistent lock must time out")
        } catch let error as RunnerError {
            try require(error.localizedDescription.contains("Timed out waiting for device unlock"), "Unlock timeout is actionable")
        }
        try require(operations == 0, "Timeout does not run installation or advance baseline")
        var unknownOperations = 0
        _ = try await gate.perform(check: { .unknown }, checkCancellation: {}, waiting: { _ in }, resuming: {}, operation: { unknownOperations += 1; return 1 })
        try require(unknownOperations == 1, "An unavailable initial probe does not falsely assert a locked device")
    }

}
