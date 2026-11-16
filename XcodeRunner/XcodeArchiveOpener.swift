import Foundation
import AppKit

enum XcodeLaunchPolicy {
    static func application(developerDirectory: String) throws -> URL {
        let supplied = URL(fileURLWithPath: developerDirectory).resolvingSymlinksInPath()
        let developer = supplied.pathExtension == "app" ? supplied.appendingPathComponent("Contents/Developer") : supplied
        let app = developer.deletingLastPathComponent().deletingLastPathComponent()
        guard developer.lastPathComponent == "Developer", developer.deletingLastPathComponent().lastPathComponent == "Contents",
              app.pathExtension == "app" else {
            throw RunnerError.message("Select a full Xcode installation in Xcode Settings → Locations → Command Line Tools before opening archives.")
        }
        return app
    }

    static func environment(from environment: [String: String]) -> [String: String] {
        // A runner launched under Xcode carries DYLD/IDE injection settings.
        // Launch Xcode as a GUI app, not as a descendant debugger target.
        let allowed: Set<String> = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "PATH", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING", "SSH_AUTH_SOCK"]
        return environment.filter { allowed.contains($0.key) }
    }
}

enum ArchiveApplicationState { case launching, ready, terminated }

@MainActor
protocol ArchiveOpenDriver: AnyObject {
    var state: ArchiveApplicationState { get }
    func launch() async throws
    func deliver(_ archive: URL) async throws
}

@MainActor
enum ArchiveHandoff {
    static func open(_ archive: URL, driver: any ArchiveOpenDriver, readinessAttempts: Int = 240, settleAttempts: Int = 8,
                     pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) },
                     cancelled: () -> Bool = { false }) async throws {
        func check() throws { if cancelled() || Task.isCancelled { throw CancellationError() } }
        try check()
        try await driver.launch()
        var ready = false
        for _ in 0..<readinessAttempts {
            try check()
            switch driver.state {
            case .ready: ready = true
            case .terminated: throw RunnerError.message("Xcode exited while starting. The archive is saved; open Xcode normally and retry Open Last Archive.")
            case .launching: break
            }
            if ready { break }
            try await pause()
        }
        guard ready else { throw RunnerError.message("Xcode did not finish launching within one minute. The archive is saved; finish any Xcode startup dialogs, then retry Open Last Archive.") }
        try check()
        try await driver.deliver(archive)
        // LaunchServices accepting a request is not proof the target survived it.
        for _ in 0..<settleAttempts {
            try check()
            if driver.state == .terminated {
                throw RunnerError.message("Xcode exited while opening the archive. The archive is saved; open Xcode normally and retry Open Last Archive.")
            }
            try await pause()
        }
        if driver.state == .terminated {
            throw RunnerError.message("Xcode exited while opening the archive. The archive is saved; open Xcode normally and retry Open Last Archive.")
        }
    }
}

@MainActor
private final class WorkspaceArchiveDriver: ArchiveOpenDriver {
    let application: URL
    private var running: NSRunningApplication?
    init(application: URL) { self.application = application }
    var state: ArchiveApplicationState {
        guard let running, !running.isTerminated else { return .terminated }
        return running.isFinishedLaunching ? .ready : .launching
    }
    private func configuration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.environment = XcodeLaunchPolicy.environment(from: ProcessInfo.processInfo.environment)
        return configuration
    }
    func launch() async throws {
        running = NSWorkspace.shared.runningApplications.first {
            !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath() == application
        }
        if running == nil {
            running = try await NSWorkspace.shared.openApplication(at: application, configuration: configuration())
        }
    }
    func deliver(_ archive: URL) async throws {
        let opened = try await NSWorkspace.shared.open([archive], withApplicationAt: application, configuration: configuration())
        running = opened
        opened.activate(options: [])
    }
}

@MainActor
enum XcodeArchiveOpener {
    static func open(_ archive: URL, cancelled: () -> Bool = { false }) async throws {
        guard archive.pathExtension == "xcarchive", FileManager.default.fileExists(atPath: archive.appendingPathComponent("Info.plist").path) else {
            throw RunnerError.message("The saved Xcode archive is missing or invalid: \(archive.path)")
        }
        let developer: String
        if let override = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !override.isEmpty { developer = override }
        else {
            developer = try await CommandRunner().run("/usr/bin/xcode-select", ["-p"], mergeStandardError: false)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let application = try XcodeLaunchPolicy.application(developerDirectory: developer)
        guard Bundle(url: application)?.bundleIdentifier == "com.apple.dt.Xcode" else {
            throw RunnerError.message("The selected developer directory does not belong to Xcode: \(developer)")
        }
        try await ArchiveHandoff.open(archive, driver: WorkspaceArchiveDriver(application: application), cancelled: cancelled)
    }
}
