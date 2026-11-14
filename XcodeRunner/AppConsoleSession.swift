import Foundation
import Combine
import Darwin

struct ConsoleLaunchCommand {
    var executable = "/usr/bin/xcrun"
    var arguments: [String]
    var environment: [String: String]
    static func make(destination: RunDestination, bundleID: String) -> Self {
        if destination.kind == .device {
            return Self(arguments: ["devicectl", "device", "process", "launch", "--device", destination.id,
                "--terminate-existing", "--console", "--environment-variables", "{\"OS_ACTIVITY_DT_MODE\":\"enable\"}", bundleID],
                environment: [:])
        }
        return Self(arguments: ["simctl", "launch", "--console-pty", "--terminate-running-process", destination.id, bundleID],
            environment: ["SIMCTL_CHILD_OS_ACTIVITY_DT_MODE": "enable", "SIMCTL_CHILD_NSUnbufferedIO": "YES"])
    }
}

struct ConsoleLaunchAcknowledgement {
    let kind: RunDestination.Kind
    let bundleID: String
    private var pending = ""
    private(set) var launched = false
    mutating func consume(_ text: String) {
        pending += text
        let lines = pending.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        pending = String(lines.last ?? "")
        for line in lines.dropLast() { check(String(line)) }
        if pending.count > 16_000 { pending = String(pending.suffix(8000)) }
    }
    mutating func finish() { check(pending); pending = "" }
    private mutating func check(_ line: String) {
        if kind == .device {
            // devicectl prints this only after connecting the launched app's console.
            if line.contains("Waiting for the application to terminate") { launched = true }
        } else {
            let line = line.trimmingCharacters(in: .whitespaces)
            let prefix = bundleID + ":"
            if line.hasPrefix(prefix), let pid = Int(line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)), pid > 0 {
                launched = true
            }
        }
    }
}

@MainActor
final class AppConsoleSession: ObservableObject, Identifiable {
    let id = UUID()
    let destination: RunDestination
    let bundleID: String
    let runSettingsKey: String?
    var appState: AppExecutionState {
        if stopped || failure != nil { return .unknown }
        if launched { return ended ? .exited : .running }
        return isRunning ? .starting : .unknown
    }
    @Published private(set) var text = ""
    @Published private(set) var status = "Connecting…"
    @Published private(set) var isRunning = false
    @Published private(set) var launched = false
    private let runner = CommandRunner(stopSignal: SIGKILL)
    private let command: ConsoleLaunchCommand
    private let buffer = CommandOutputBuffer()
    private var acknowledgement: ConsoleLaunchAcknowledgement
    private var operation: Task<Void, Never>?
    private var ended = false
    private var stopped = false
    private var failure: String?

    init(destination: RunDestination, bundleID: String, runSettingsKey: String? = nil, launchCommand: ConsoleLaunchCommand? = nil) {
        self.destination = destination; self.bundleID = bundleID; self.runSettingsKey = runSettingsKey
        command = launchCommand ?? ConsoleLaunchCommand.make(destination: destination, bundleID: bundleID)
        acknowledgement = ConsoleLaunchAcknowledgement(kind: destination.kind, bundleID: bundleID)
    }
    func start(directory: String) {
        guard operation == nil, !stopped else { return }
        isRunning = true
        append("\(bundleID) · \(destination.name)\n\(Date().formatted())\n\n")
        operation = Task { [self] in
            let pump = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    receive()
                }
            }
            do {
                // A real PTY enables console forwarding. No lifetime timeout: this
                // process deliberately remains alive after launch has succeeded.
                _ = try await runner.run(command.executable, command.arguments, directory: directory,
                    timeout: nil, environment: command.environment, usePTY: true, captureLimit: 4000) { [buffer] text in buffer.append(text) }
            } catch {
                if !stopped { failure = error.localizedDescription }
            }
            pump.cancel()
            receive()
            acknowledgement.finish()
            launched = acknowledgement.launched
            ended = true; isRunning = false
            if stopped { status = "Disconnected" }
            else if let failure { status = "Connection ended"; append("\n\(failure)\n") }
            else { status = launched ? "App exited" : "Launch not confirmed" }
            append("\n— \(status) —\n")
        }
    }
    func waitForLaunch(timeout: Duration = .seconds(45)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !launched {
            if stopped { throw CancellationError() }
            if ended { throw RunnerError.message(failure ?? "Console ended before app launch was confirmed. See App Console.") }
            if ContinuousClock.now >= deadline {
                stop()
                throw RunnerError.message("App launch timed out before console confirmation. See App Console for details.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        status = isRunning ? "Disconnecting…" : "Disconnected"
        // Catchable signals are forwarded to the app by Apple's console tools.
        // Kill the local forwarding process directly instead.
        runner.cancel()
    }
    func stopAndWait() async { stop(); await operation?.value }
    func clear() {
        text = ""
    }
    private func receive() {
        let chunk = buffer.drain()
        guard !chunk.isEmpty else { return }
        append(chunk)
        acknowledgement.consume(chunk)
        if !launched && acknowledgement.launched {
            launched = true
            if !stopped { status = "Live" }
        }
    }
    private func append(_ chunk: String) {
        text += chunk.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.count > 250_000 { text = String(text.suffix(200_000)) }
    }
}

enum ConsoleText {
    static func filtered(_ text: String, query: String) -> String {
        guard !query.isEmpty else { return text }
        return text.components(separatedBy: "\n").filter { $0.localizedCaseInsensitiveContains(query) }.joined(separator: "\n")
    }
}


enum AppExecutionState: Equatable, Sendable {
    case running, exited, starting, unknown, waitingForUnlock
    var label: String {
        switch self {
        case .running: return "App Running"
        case .exited: return "App Exited"
        case .starting: return "App Starting"
        case .unknown: return "App Unknown"
        case .waitingForUnlock: return "Unlock Device"
        }
    }
    var detail: String {
        switch self {
        case .running: return "The console is attached to the launched app. It may be in the foreground or background."
        case .exited: return "The attached app has exited."
        case .starting: return "Waiting for app launch and console connection."
        case .waitingForUnlock: return "Unlock your device within two minutes to continue the run automatically."
        case .unknown: return "No active console for this scheme and destination. Run or Launch Again to track the app."
        }
    }
}
