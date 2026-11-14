import Foundation

enum DeviceLockState: Equatable, Sendable {
    case locked, unlocked, unknown

    static func parse(_ data: Data) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any] else { return .unknown }
        if result["passcodeRequired"] as? Bool == true || result["unlockedSinceBoot"] as? Bool == false { return .locked }
        if result["passcodeRequired"] as? Bool == false { return .unlocked }
        return .unknown
    }

    static func isLockFailure(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return ["device is locked", "device was locked", "device locked", "device must be unlocked",
                "device was not unlocked", "unlock the device", "unlock your device", "deviceislocked"]
            .contains { text.contains($0) }
    }

    static func query(destination: RunDestination, runner: CommandRunner) async throws -> Self {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await runner.run("/usr/bin/xcrun", ["devicectl", "device", "info", "lockState",
            "--device", destination.id, "--timeout", "5", "--quiet", "--json-output", file.path], timeout: 8)
        return try parse(Data(contentsOf: file))
    }
}

/// A single, bounded unlock window shared by preflight and lock-race retries.
@MainActor
struct DeviceUnlockGate {
    var timeout: Duration = .seconds(120)
    var pollInterval: Duration = .seconds(2)

    func perform<T>(check: () async throws -> DeviceLockState,
                    checkCancellation: () throws -> Void,
                    waiting: (Int) -> Void,
                    resuming: () -> Void,
                    operation: () async throws -> T) async throws -> T {
        var deadline: ContinuousClock.Instant?
        var requireConfirmation = false
        while true {
            try checkCancellation()
            if let deadline, ContinuousClock.now >= deadline { throw timedOut() }
            let state: DeviceLockState
            do { state = try await check() }
            catch is CancellationError { throw CancellationError() }
            catch {
                try checkCancellation()
                // A failed initial probe is not evidence that a device is locked.
                // After a confirmed lock, keep waiting rather than assume unlock.
                state = .unknown
            }
            try checkCancellation()
            if let deadline, ContinuousClock.now >= deadline { throw timedOut() }
            if state == .locked || (requireConfirmation && state != .unlocked) {
                if deadline == nil { deadline = ContinuousClock.now + timeout }
                requireConfirmation = true
                let remaining = ContinuousClock.now.duration(to: deadline!)
                waiting(max(0, Int(ceil(Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18))))
                try await Task.sleep(for: min(pollInterval, remaining))
                continue
            }
            resuming()
            do { return try await operation() }
            catch {
                try checkCancellation()
                guard !(error is CancellationError), DeviceLockState.isLockFailure(error) else { throw error }
                if deadline == nil { deadline = ContinuousClock.now + timeout }
                requireConfirmation = true
                if ContinuousClock.now >= deadline! { throw timedOut() }
                // Even a rapid lock/unlock race must not spin or restart its budget.
                try await Task.sleep(for: min(pollInterval, ContinuousClock.now.duration(to: deadline!)))
            }
        }
    }
    private func timedOut() -> RunnerError {
        .message("Timed out waiting for device unlock. Unlock the device and press Run again. Changes remain pending.")
    }
}
