import Foundation

@main
struct RegressionChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw RunnerError.message("FAIL: " + message) }
    }
    @MainActor
    static func archiveHandoffChecks() async throws {
        let archive = URL(fileURLWithPath: "/tmp/Archive With Spaces.xcarchive")
        let cold = ArchiveDriverProbe(states: [.launching, .launching, .ready])
        try await ArchiveHandoff.open(archive, driver: cold, readinessAttempts: 4, settleAttempts: 0, pause: { cold.advance() })
        try require(cold.events == ["launch", "wait", "wait", "deliver"], "Cold Xcode launch finishes before the archive is delivered")
        let warm = ArchiveDriverProbe(states: [.ready])
        try await ArchiveHandoff.open(archive, driver: warm, readinessAttempts: 2, settleAttempts: 0, pause: { warm.advance() })
        try require(warm.events == ["launch", "deliver"], "Already-running Xcode receives an explicit archive-open request")
        let startupCrash = ArchiveDriverProbe(states: [.launching, .terminated])
        var startupRejected = false
        do { try await ArchiveHandoff.open(archive, driver: startupCrash, readinessAttempts: 3, settleAttempts: 0, pause: { startupCrash.advance() }) }
        catch { startupRejected = true }
        try require(startupRejected && !startupCrash.events.contains("deliver"), "Startup crashes never receive a file-open event or report handoff success")
        let timeout = ArchiveDriverProbe(states: [.launching])
        var timeoutRejected = false
        do { try await ArchiveHandoff.open(archive, driver: timeout, readinessAttempts: 2, settleAttempts: 0, pause: { timeout.advance() }) }
        catch { timeoutRejected = true }
        try require(timeoutRejected && !timeout.events.contains("deliver"), "Xcode startup waits are bounded")
        let openCrash = ArchiveDriverProbe(states: [.ready, .ready, .terminated])
        var openRejected = false
        do { try await ArchiveHandoff.open(archive, driver: openCrash, readinessAttempts: 2, settleAttempts: 2, pause: { openCrash.advance() }) }
        catch { openRejected = true }
        try require(openRejected && openCrash.events.contains("deliver"), "An immediate Xcode exit after archive delivery is reported as failure")
        let cancelled = ArchiveDriverProbe(states: [.ready])
        var cancellationRejected = false
        do { try await ArchiveHandoff.open(archive, driver: cancelled, readinessAttempts: 2, settleAttempts: 0, cancelled: { true }) }
        catch is CancellationError { cancellationRejected = true }
        try require(cancellationRejected && cancelled.events.isEmpty, "Cancelling handoff avoids launching Xcode")
        let clean = XcodeLaunchPolicy.environment(from: ["HOME": "/Users/test", "PATH": "/usr/bin", "DYLD_FRAMEWORK_PATH": "/bad", "DYLD_INSERT_LIBRARIES": "/bad/injection.dylib", "__XCODE_BUILT_PRODUCTS_DIR_PATHS": "/bad", "__CFBundleIdentifier": "runner", "IDE_TEST_HOST": "runner"])
        try require(clean == ["HOME": "/Users/test", "PATH": "/usr/bin"], "Xcode startup never inherits runner debugger or framework-injection settings")
        let selected = try XcodeLaunchPolicy.application(developerDirectory: "/Applications/Xcode Beta.app/Contents/Developer")
        try require(selected.path == "/Applications/Xcode Beta.app", "Archive handoff targets the selected Xcode installation rather than an app name")
        let selectedApp = try XcodeLaunchPolicy.application(developerDirectory: "/Applications/Xcode Beta.app")
        try require(selectedApp == selected, "DEVELOPER_DIR also accepts an Xcode app path")
        var toolsRejected = false
        do { _ = try XcodeLaunchPolicy.application(developerDirectory: "/Library/Developer/CommandLineTools") }
        catch { toolsRejected = true }
        try require(toolsRejected, "Command Line Tools alone cannot masquerade as Xcode for archive opening")
    }

    static func main() async throws {
        try await archiveHandoffChecks()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("XcodeRunner-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Version edits must preserve the rest of the project and refuse stale writes.
        let versionOriginal = try Data(contentsOf: URL(fileURLWithPath: "XcodeRunner.xcodeproj/project.pbxproj"))
        let versionPlist = try PropertyListSerialization.propertyList(from: versionOriginal, format: nil) as! [String: Any]
        let versionObjects = versionPlist["objects"] as! [String: [String: Any]]
        let versionID = versionObjects.first { _, object in
            let settings = object["buildSettings"] as? [String: Any]
            return object["name"] as? String == "Debug" && settings?["MARKETING_VERSION"] != nil
        }!.key
        let versionFile = root.appendingPathComponent("version.pbxproj")
        try versionOriginal.write(to: versionFile)
        let versionModel = ProjectVersion(target: "App", configuration: "Debug", version: "1.0", build: "1",
            file: versionFile, original: versionOriginal, configurationID: versionID, editable: true)
        let versionEdited = try versionModel.editedSource(version: "2.3.4", build: "42")
        let editedPlist = try PropertyListSerialization.propertyList(from: versionEdited, format: nil) as! [String: Any]
        let editedObjects = editedPlist["objects"] as! [String: [String: Any]]
        let editedSettings = editedObjects[versionID]!["buildSettings"] as! [String: Any]
        try require(editedSettings["MARKETING_VERSION"] as? String == "2.3.4" && editedSettings["CURRENT_PROJECT_VERSION"] as? String == "42", "Version and build edit selected configuration")
        var expectedObjects = versionObjects
        expectedObjects[versionID] = editedObjects[versionID]
        try require(NSDictionary(dictionary: expectedObjects).isEqual(to: editedObjects), "Other targets and configurations remain intact")
        try require(ProjectVersion.bumped("1.2.3", component: 1) == "1.3.0" && ProjectVersion.bumped("42") == "43", "Version bumps reset lower components and increment builds")
        try require(!ProjectVersion.valid("$(INHERITED)") && !ProjectVersion.valid("1.2; injected"), "Reject expressions and nonnumeric versions")
        try Data("changed".utf8).write(to: versionFile)
        do {
            try versionModel.save(version: "2.3.4", build: "42")
            throw RunnerError.message("FAIL: stale version editor overwrote project")
        } catch {
            let preserved = try String(contentsOf: versionFile, encoding: .utf8)
            try require(preserved == "changed", "External edits prevent version save")
        }
        let versionPackage = root.appendingPathComponent("VersionFixture.xcodeproj")
        try FileManager.default.createDirectory(at: versionPackage, withIntermediateDirectories: true)
        let projectFile = versionPackage.appendingPathComponent("project.pbxproj")
        try versionOriginal.write(to: projectFile)
        let infoFile = root.appendingPathComponent("VersionInfo.plist")
        let mixedInfo = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "$(MARKETING_VERSION)", "CFBundleVersion": "1", "Unrelated": "preserve me"], format: .xml, options: 0)
        try mixedInfo.write(to: infoFile)
        let fixtureMarketingVersion = (versionObjects[versionID]!["buildSettings"] as! [String: Any])["MARKETING_VERSION"] as! String
        var fixtureSettings: [String: Any] = ["PROJECT_DIR": root.path, "INFOPLIST_FILE": "VersionInfo.plist", "MARKETING_VERSION": fixtureMarketingVersion, "CURRENT_PROJECT_VERSION": "Marketing Version"]
        let mixedVersion = try ProjectVersion.read(settings: fixtureSettings, target: "XcodeRunner", path: versionPackage.path, configuration: "Debug")
        try require(mixedVersion.editable && mixedVersion.build == "1" && mixedVersion.projectKeys == ["MARKETING_VERSION"] && mixedVersion.plistKeys == ["CFBundleVersion"], "Mixed plist/build-settings versions remain editable despite unused nonnumeric build setting")
        try mixedVersion.save(version: "2.0.0", build: "2")
        let syncedProject = try PropertyListSerialization.propertyList(from: Data(contentsOf: projectFile), format: nil) as! [String: Any]
        let syncedObjects = syncedProject["objects"] as! [String: [String: Any]]
        for id in mixedVersion.targetConfigurationIDs {
            let configSettings = syncedObjects[id]!["buildSettings"] as! [String: Any]
            try require(configSettings["MARKETING_VERSION"] as? String == "2.0.0", "Version save syncs Debug and Release for archiving")
        }
        for (id, object) in versionObjects where !mixedVersion.targetConfigurationIDs.contains(id) {
            try require(NSDictionary(dictionary: object).isEqual(to: syncedObjects[id]!), "Version sync preserves other targets and project settings")
        }
        let savedInfo = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoFile), format: nil) as! [String: String]
        try require(savedInfo["CFBundleVersion"] == "2" && savedInfo["CFBundleShortVersionString"] == "$(MARKETING_VERSION)" && savedInfo["Unrelated"] == "preserve me", "Mixed save edits only literal build plist key")
        let hardcoded = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "1.1", "CFBundleVersion": "1"], format: .binary, options: 0)
        try hardcoded.write(to: infoFile)
        let literalVersion = try ProjectVersion.read(settings: fixtureSettings, target: "XcodeRunner", path: versionPackage.path, configuration: "Debug")
        try require(literalVersion.editable && literalVersion.projectKeys.isEmpty && literalVersion.version == "1.1", "Literal plist versions can be edited")
        let beforeLiteralSave = try Data(contentsOf: projectFile)
        try literalVersion.save(version: "1.2", build: "3")
        let afterLiteralSave = try Data(contentsOf: projectFile)
        var binaryFormat = PropertyListSerialization.PropertyListFormat.xml
        let binarySaved = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoFile), format: &binaryFormat) as! [String: String]
        try require(beforeLiteralSave == afterLiteralSave && binaryFormat == .binary && binarySaved["CFBundleVersion"] == "3", "Plist-only edits preserve project bytes and binary plist format")
        fixtureSettings["INFOPLIST_FILE"] = "Missing.plist"
        let unavailable = try ProjectVersion.read(settings: fixtureSettings, target: "XcodeRunner", path: versionPackage.path, configuration: "Debug")
        try require(!unavailable.editable && unavailable.unavailableReason != nil, "Unsupported sources give an explicit reason")
        // Reproduce a bump saved only to Debug, followed immediately by Archive.
        try versionOriginal.write(to: projectFile)
        try mixedInfo.write(to: infoFile)
        fixtureSettings["INFOPLIST_FILE"] = "VersionInfo.plist"
        fixtureSettings["MARKETING_VERSION"] = fixtureMarketingVersion
        let beforeBump = try ProjectVersion.read(settings: fixtureSettings, target: "XcodeRunner", path: versionPackage.path, configuration: "Debug")
        try beforeBump.editedSource(version: "2.26.2", build: "1").write(to: projectFile)
        fixtureSettings["MARKETING_VERSION"] = "2.26.2"
        let pendingArchive = try ProjectVersion.read(settings: fixtureSettings, target: "XcodeRunner", path: versionPackage.path, configuration: "Debug")
        try pendingArchive.syncForArchive()
        let preflightPlist = try PropertyListSerialization.propertyList(from: Data(contentsOf: projectFile), format: nil) as! [String: Any]
        let preflightObjects = preflightPlist["objects"] as! [String: [String: Any]]
        for id in pendingArchive.targetConfigurationIDs {
            let configSettings = preflightObjects[id]!["buildSettings"] as! [String: Any]
            try require(configSettings["MARKETING_VERSION"] as? String == "2.26.2", "Archive preflight syncs a previous Debug-only bump before building Release")
        }
        try FileManager.default.removeItem(at: versionPackage)
        try FileManager.default.removeItem(at: infoFile)
        try FileManager.default.removeItem(at: versionFile)
        let archiveRoot = root.appendingPathComponent("Archives")
        let archiveProject = TrackedProject(containerPath: root.appendingPathComponent("App With Spaces.xcworkspace").path,
            rootPath: root.path, schemes: ["App iOS"], scheme: "App iOS", configuration: "Debug", destinationID: "simulator-id")
        let archivePlan = ArchivePlan(project: archiveProject, archives: archiveRoot, date: Date(timeIntervalSince1970: 0))
        try require(archivePlan.arguments.prefix(4) == ["-workspace", archiveProject.containerPath, "-scheme", "App iOS"], "Archive preserves container and scheme argument boundaries")
        try require(archivePlan.arguments.contains("generic/platform=iOS") && !archivePlan.arguments.contains("simulator-id") && !archivePlan.arguments.contains("-configuration") && archivePlan.arguments.last == "archive", "Archive uses generic device and scheme Archive configuration independently of run settings")
        let secondPlan = ArchivePlan(project: archiveProject, archives: archiveRoot, date: Date(timeIntervalSince1970: 0))
        try require(archivePlan.path != secondPlan.path && archivePlan.path.pathExtension == "xcarchive", "Archive names never overwrite previous archives")
        try FileManager.default.createDirectory(at: archivePlan.path, withIntermediateDirectories: true)
        let genericArchiveInfo = try PropertyListSerialization.data(fromPropertyList: ["ArchiveVersion": 2], format: .xml, options: 0)
        try genericArchiveInfo.write(to: archivePlan.path.appendingPathComponent("Info.plist"))
        var rejectedGenericArchive = false
        do { try archivePlan.validate() } catch { rejectedGenericArchive = true }
        try require(rejectedGenericArchive, "Generic archives are not presented as distributable app archives")
        let appArchiveInfo = try PropertyListSerialization.data(fromPropertyList: ["ApplicationProperties": ["ApplicationPath": "Applications/Test App.app"]], format: .xml, options: 0)
        try appArchiveInfo.write(to: archivePlan.path.appendingPathComponent("Info.plist"))
        try FileManager.default.createDirectory(at: archivePlan.path.appendingPathComponent("Products/Applications/Test App.app"), withIntermediateDirectories: true)
        try archivePlan.validate()
        let archivedAppInfo = archivePlan.path.appendingPathComponent("Products/Applications/Test App.app/Info.plist")
        let staleArchiveInfo = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "2.26.1", "CFBundleVersion": "1"], format: .binary, options: 0)
        try staleArchiveInfo.write(to: archivedAppInfo)
        var rejectedStaleVersion = false
        do { try archivePlan.validate(expectedVersion: "2.26.2", expectedBuild: "1") }
        catch { rejectedStaleVersion = error.localizedDescription.contains("Archive version mismatch") }
        try require(rejectedStaleVersion, "Previous-version archives are detected before Organizer opens")
        try archivePlan.validate(expectedVersion: "2.26.1", expectedBuild: "1")
        var rejectedStaleBuild = false
        do { try archivePlan.validate(expectedVersion: "2.26.1", expectedBuild: "2") }
        catch { rejectedStaleBuild = true }
        try require(rejectedStaleBuild, "Archive build number is verified too")
        try FileManager.default.removeItem(at: archiveRoot)
        let iconRoot = root.appendingPathComponent("IconFixtures")
        let iconSet = iconRoot.appendingPathComponent("Assets.xcassets/Target Icon.appiconset")
        try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
        let iconManifest: [String: Any] = ["images": [
            ["filename": "small.png", "idiom": "iphone", "size": "60x60", "scale": "2x"],
            ["filename": "large.png", "idiom": "universal", "size": "1024x1024"],
            ["filename": "dark.png", "idiom": "universal", "size": "1024x1024", "appearances": [["appearance": "luminosity", "value": "dark"]]],
            ["filename": "missing.png", "idiom": "universal", "size": "1024x1024"]
        ]]
        try JSONSerialization.data(withJSONObject: iconManifest).write(to: iconSet.appendingPathComponent("Contents.json"))
        for name in ["small.png", "large.png", "dark.png"] { try Data().write(to: iconSet.appendingPathComponent(name)) }
        let iconCandidates = ProjectAppIcon.files(root: iconRoot, name: "Target Icon")
        try require(iconCandidates.map(\.lastPathComponent) == ["large.png", "small.png"], "Sidebar icons prefer large default artwork and skip dark/missing assets")
        try require(ProjectAppIcon.files(root: iconRoot, name: "Different Target").isEmpty, "Sidebar resolves the configured icon name instead of another target's icon")
        let duplicateSet = iconRoot.appendingPathComponent("Other/Assets.xcassets/Target Icon.appiconset")
        try FileManager.default.createDirectory(at: duplicateSet, withIntermediateDirectories: true)
        try require(ProjectAppIcon.files(root: iconRoot, name: "Target Icon").isEmpty, "Ambiguous icon catalogs fall back rather than show the wrong app")
        let iconProject = iconRoot.appendingPathComponent("Fixture.xcodeproj")
        try FileManager.default.createDirectory(at: iconProject, withIntermediateDirectories: true)
        let iconObjects: [String: Any] = ["objects": [
            "APP": ["isa": "PBXNativeTarget", "name": "App", "buildPhases": ["RESOURCES"]],
            "RESOURCES": ["isa": "PBXResourcesBuildPhase", "files": ["BUILD_FILE"]],
            "BUILD_FILE": ["fileRef": "CATALOG"],
            "ROOT": ["isa": "PBXGroup", "children": ["SHARED"]],
            "SHARED": ["isa": "PBXGroup", "path": ".", "children": ["CATALOG"], "sourceTree": "<group>"],
            "CATALOG": ["isa": "PBXFileReference", "path": "Assets.xcassets", "sourceTree": "<group>"]
        ]]
        try PropertyListSerialization.data(fromPropertyList: iconObjects, format: .xml, options: 0).write(to: iconProject.appendingPathComponent("project.pbxproj"))
        let targetCatalogs = ProjectAppIcon.catalogRoots(project: iconProject, target: "App", sourceRoot: iconRoot)
        try require(targetCatalogs.count == 1 && targetCatalogs[0].standardizedFileURL.path == iconRoot.appendingPathComponent("Assets.xcassets").standardizedFileURL.path, "Icon catalogs resolve from target resource references through parent groups")
        try require(ProjectAppIcon.files(roots: targetCatalogs, name: "Target Icon").count == 2, "Dependency demo icons do not make the selected app target ambiguous")
        try FileManager.default.removeItem(at: iconRoot)
        let cacheDirectory = root.appendingPathComponent("IconCache")
        let cacheInput = root.appendingPathComponent("icon-input.png")
        try Data("old-icon".utf8).write(to: cacheInput)
        let cacheProject = TrackedProject(containerPath: root.appendingPathComponent("App.xcodeproj").path,
            rootPath: root.path, schemes: ["App"], scheme: "App", configuration: "Debug")
        let iconCache = ProjectIconCache(directory: cacheDirectory)
        let thumbnailBytes = Data("cached-thumbnail".utf8)
        try iconCache.save(thumbnailBytes, for: cacheProject, inputs: [cacheInput])
        let relaunchedCache = ProjectIconCache(directory: cacheDirectory)
        let persistedIcon = relaunchedCache.load(cacheProject)
        try require(persistedIcon?.data == thumbnailBytes && persistedIcon?.fresh == true, "Disk icon cache survives a new cache instance without metadata rediscovery")
        try Data("new-icon".utf8).write(to: cacheInput)
        let staleIcon = relaunchedCache.load(cacheProject)
        try require(staleIcon?.fresh == false && staleIcon?.data == thumbnailBytes, "Same-size artwork edits invalidate metadata while keeping cached artwork available during refresh")
        var differentScheme = cacheProject
        differentScheme.scheme = "Another App"
        try require(relaunchedCache.load(differentScheme) == nil, "Icon cache does not reuse another scheme's artwork")
        differentScheme = cacheProject
        differentScheme.configuration = "Release"
        try require(relaunchedCache.load(differentScheme) == nil, "Configuration-specific icons have distinct cache keys")
        try FileManager.default.removeItem(at: cacheInput)
        try require(relaunchedCache.load(cacheProject)?.fresh == false, "Missing icon sources trigger refresh rather than a false cache hit")
        try Data("corrupt cache".utf8).write(to: cacheDirectory.appendingPathComponent(ProjectIconCache.key(for: cacheProject) + ".json"))
        try require(relaunchedCache.load(cacheProject) == nil, "Corrupt icon caches fall back to discovery")
        try FileManager.default.removeItem(at: cacheDirectory)
        let gitRoot = root.appendingPathComponent("GitFixture")
        try FileManager.default.createDirectory(at: gitRoot.appendingPathComponent("Nested"), withIntermediateDirectories: true)
        let gitRunner = CommandRunner()
        func git(_ arguments: [String]) async throws {
            _ = try await gitRunner.run("/usr/bin/git", ["-C", gitRoot.path, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"] + arguments,
                environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
        }
        try await git(["init", "--quiet"])
        try await git(["config", "user.name", "Regression Test"])
        try await git(["config", "user.email", "test@example.invalid"])
        try await git(["config", "status.renames", "true"])
        for name in ["tracked.swift", "staged.swift", "deleted.swift", "old name.swift", "dual.swift", "Nested/Inside.swift"] {
            try Data("first".utf8).write(to: gitRoot.appendingPathComponent(name))
        }
        try Data("ignored/\n".utf8).write(to: gitRoot.appendingPathComponent(".gitignore"))
        try await git(["add", "."])
        try await git(["commit", "--quiet", "-m", "Fixture"])
        try Data("other".utf8).write(to: gitRoot.appendingPathComponent("tracked.swift"))
        try Data("stage".utf8).write(to: gitRoot.appendingPathComponent("staged.swift"))
        try Data("stage".utf8).write(to: gitRoot.appendingPathComponent("dual.swift"))
        try await git(["add", "staged.swift", "dual.swift"])
        try Data("again".utf8).write(to: gitRoot.appendingPathComponent("dual.swift"))
        try FileManager.default.removeItem(at: gitRoot.appendingPathComponent("deleted.swift"))
        try await git(["mv", "old name.swift", "renamed -> file.swift"])
        let unusualPath = "new file\n名前.swift"
        try Data("new".utf8).write(to: gitRoot.appendingPathComponent(unusualPath))
        try FileManager.default.createDirectory(at: gitRoot.appendingPathComponent("ignored"), withIntermediateDirectories: true)
        try Data("noise".utf8).write(to: gitRoot.appendingPathComponent("ignored/generated.swift"))
        let gitSnapshot = try await GitChanges.read(root: gitRoot.path)
        let gitFiles = Dictionary(uniqueKeysWithValues: gitSnapshot.changes.map { ($0.path, $0) })
        try require(!gitSnapshot.branch.isEmpty && !gitSnapshot.branch.hasPrefix("Detached "), "Git snapshot includes the current branch")
        try require(gitFiles["tracked.swift"]?.lastModified != nil && gitFiles[unusualPath]?.lastModified != nil && gitFiles["deleted.swift"]?.lastModified == nil, "Changed-file rows expose real working-file edit times and no fabricated timestamp for deletions")
        try require(gitFiles["tracked.swift"]?.lineStats == GitLineStats(additions: 1, deletions: 1) && gitFiles["staged.swift"]?.lineStats == GitLineStats(additions: 1, deletions: 1), "File rows receive HEAD-relative added/deleted line counts for staged and unstaged changes")
        try require(gitFiles["deleted.swift"]?.lineStats == GitLineStats(additions: 0, deletions: 1) && gitFiles[unusualPath]?.lineStats == GitLineStats(additions: 1, deletions: 0), "Deleted and untracked files have inline counts without opening review")
        try require(gitFiles["renamed -> file.swift"]?.lineStats == GitLineStats(additions: 0, deletions: 0), "Pure rename counts attach to the new path")
        let parsedStats = try GitLineCounts.parse("12\t3\tpath\twith tab\n名前.swift\0-\t-\tbinary.png\00\t0\t\0old name.swift\0new name.swift\0")
        try require(parsedStats["path\twith tab\n名前.swift"]?.additions == 12 && parsedStats["binary.png"]?.binary == true && parsedStats["new name.swift"]?.deletions == 0, "NUL numstat parsing preserves tabs/newlines, binary markers, and rename pairs")
        try require(gitFiles.count == 6 && gitFiles["ignored/generated.swift"] == nil, "Git counts staged, unstaged, untracked, deleted, and renamed files while respecting gitignore")
        try require(gitFiles["tracked.swift"]?.gitStatus == " M" && gitFiles["staged.swift"]?.gitStatus == "M " && gitFiles["dual.swift"]?.gitStatus == "MM", "Git preserves index and working-tree status separately")
        try require(gitFiles["renamed -> file.swift"]?.originalPath == "old name.swift" && gitFiles[unusualPath]?.kind == "Untracked", "NUL-delimited Git parsing preserves rename paths, spaces, newlines, and Unicode")
        try Data("third".utf8).write(to: gitRoot.appendingPathComponent("tracked.swift"))
        let unstagedDiff = try await GitDiff.load(root: gitRoot.path, change: gitFiles["tracked.swift"]!, scope: .unstaged)
        try require(unstagedDiff.additions == 1 && unstagedDiff.deletions == 1, "Unstaged review shows real working-tree additions and deletions")
        try require(unstagedDiff.lines.first { $0.kind == .addition }?.newLine == 1 && unstagedDiff.lines.first { $0.kind == .deletion }?.oldLine == 1, "Diff gutters carry accurate old and new line numbers")
        let stagedDiff = try await GitDiff.load(root: gitRoot.path, change: gitFiles["staged.swift"]!, scope: .staged)
        let stagedWorkingDiff = try await GitDiff.load(root: gitRoot.path, change: gitFiles["staged.swift"]!, scope: .unstaged)
        try require(stagedDiff.additions == 1 && stagedWorkingDiff.message != nil, "Staged and unstaged review remain distinct")
        let combinedDiff = try await GitDiff.load(root: gitRoot.path, change: gitFiles["dual.swift"]!, scope: .all)
        try require(combinedDiff.lines.contains { $0.kind == .addition && $0.text == "again" } && combinedDiff.lines.contains { $0.kind == .deletion && $0.text == "first" }, "All Changes compares HEAD with the current working tree")
        let newFileDiff = try await GitDiff.load(root: gitRoot.path, change: gitFiles[unusualPath]!, scope: .all)
        try require(newFileDiff.additions == 1 && newFileDiff.deletions == 0, "Untracked text files preview as additions, including unusual filenames")
        let renameDiff = try await GitDiff.load(root: gitRoot.path, change: gitFiles["renamed -> file.swift"]!, scope: .staged)
        try require(renameDiff.rawText.contains("rename from old name.swift") && renameDiff.rawText.contains("rename to renamed -> file.swift"), "Review retains rename metadata")
        let deletedDiff = try await GitDiff.load(root: gitRoot.path, change: gitFiles["deleted.swift"]!, scope: .all)
        try require(deletedDiff.deletions == 1 && deletedDiff.additions == 0, "Deleted files remain reviewable")
        let binaryPath = "binary.dat"
        try Data([0, 1, 2]).write(to: gitRoot.appendingPathComponent(binaryPath))
        let binaryDiff = try await GitDiff.load(root: gitRoot.path, change: FileChange(path: binaryPath, kind: "Untracked", gitStatus: "??"), scope: .all)
        try require(binaryDiff.binary && binaryDiff.message != nil, "Binary additions get an explicit preview state")
        let multiHunk = GitDiff.parse("@@ -4,2 +4,2 @@\n same\n-old\n+new\n\\ No newline at end of file\n@@ -20 +30,2 @@\n context\n+++literal\n")
        try require(multiHunk.lines.last?.text == "++literal" && multiHunk.lines.last?.newLine == 31 && multiHunk.lines.last?.oldLine == nil, "Multiple hunks, no-newline markers, and code beginning with plus signs parse correctly")
        let editedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: editedAt], ofItemAtPath: gitRoot.appendingPathComponent("tracked.swift").path)
        let newerGitSnapshot = try await GitChanges.read(root: gitRoot.path)
        try require(abs((newerGitSnapshot.changes.first { $0.path == "tracked.swift" }?.lastModified?.timeIntervalSince1970 ?? 0) - editedAt.timeIntervalSince1970) < 1, "Edit timestamps refresh from the filesystem rather than scan time or commit time")
        try require(newerGitSnapshot.changes.first { $0.path == binaryPath }?.lineStats?.binary == true, "Binary file rows show a binary state rather than misleading zero line counts")
        try require(gitSnapshot.fingerprint != newerGitSnapshot.fingerprint, "Further edits with unchanged Git status still invalidate Launch Again's last-built-source check")
        try Data("other".utf8).write(to: gitRoot.appendingPathComponent("Nested/Inside.swift"))
        let nestedGit = try await GitChanges.read(root: gitRoot.appendingPathComponent("Nested").path)
        try require(nestedGit.changes.count == 1 && nestedGit.changes.first?.path == "Nested/Inside.swift", "Nested projects scope Git changes to their own folder with repository-relative paths")
        let nestedReview = try await GitDiff.load(root: gitRoot.appendingPathComponent("Nested").path, change: nestedGit.changes[0], scope: .all)
        try require(nestedReview.additions == 1 && nestedReview.deletions == 1, "Repository-relative diff paths work when the selected project is nested")
        let conflicts = try GitChanges.parse("UU conflicted.swift\0")
        try require(conflicts.first?.kind == "Conflict", "Unmerged Git records surface conflicts")
        try await git(["checkout", "-b", "review/branch-indicator"])
        let switchedBranch = try await GitChanges.read(root: gitRoot.path)
        try require(switchedBranch.branch == "review/branch-indicator", "Branch indicator refreshes after switching branches")
        try await git(["checkout", "--detach", "HEAD"])
        let detachedBranch = try await GitChanges.read(root: gitRoot.path)
        try require(detachedBranch.branch.hasPrefix("Detached "), "Detached HEAD shows its revision instead of a stale branch name")
        try FileManager.default.removeItem(at: gitRoot)
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

@MainActor
private final class ArchiveDriverProbe: ArchiveOpenDriver {
    let states: [ArchiveApplicationState]
    private var index = 0
    var events: [String] = []
    var state: ArchiveApplicationState { states[min(index, states.count - 1)] }
    init(states: [ArchiveApplicationState]) { self.states = states }
    func launch() async throws { events.append("launch") }
    func deliver(_ archive: URL) async throws {
        guard state == .ready else { throw RunnerError.message("Archive delivered before Xcode was ready") }
        events.append("deliver")
    }
    func advance() { events.append("wait"); index += 1 }
}
