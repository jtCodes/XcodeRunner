import Foundation
import Darwin

/// One command at a time per instance; blocking reads run off the UI thread.
final class CommandRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private let stopSignal: Int32

    init(stopSignal: Int32 = SIGTERM) { self.stopSignal = stopSignal }

    func cancel() {
        let running = lock.withLock { cancelled = true; return process }
        if let running { Self.stop(running, signal: stopSignal) }
    }

    private static func stop(_ process: Process, signal: Int32 = SIGTERM) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        if getpgid(pid) == pid { kill(-pid, signal) } else { kill(pid, signal) }
        guard signal != SIGKILL else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning {
                if getpgid(pid) == pid { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) }
            }
        }
    }

    func run(_ executable: String, _ arguments: [String], directory: String? = nil,
             timeout: TimeInterval? = 120, environment overrides: [String: String] = [:],
             usePTY: Bool = false, captureLimit: Int = 16_000_000, mergeStandardError: Bool = true,
             output: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        try await Task.detached { [self] in
            let child = Process()
            child.executableURL = URL(fileURLWithPath: executable)
            child.arguments = arguments
            if let directory { child.currentDirectoryURL = URL(fileURLWithPath: directory) }
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            environment["NSUnbufferedIO"] = "YES"
            environment.merge(overrides) { _, new in new }
            child.environment = environment
            let pipe = Pipe()
            let errorPipe = Pipe()
            let stderr = CommandStderrCapture()
            let stderrDrain = DispatchGroup()
            var terminalReader: FileHandle?
            var terminalWriter: FileHandle?
            if usePTY {
                var master: Int32 = -1
                var slave: Int32 = -1
                guard openpty(&master, &slave, nil, nil, nil) == 0 else { throw POSIXError(.EIO) }
                terminalReader = FileHandle(fileDescriptor: master, closeOnDealloc: true)
                terminalWriter = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
                child.standardOutput = terminalWriter
                child.standardError = terminalWriter
                child.standardInput = terminalWriter
            } else {
                child.standardOutput = pipe
                child.standardError = mergeStandardError ? pipe : errorPipe
                child.standardInput = FileHandle.nullDevice
            }
            let reader = terminalReader ?? pipe.fileHandleForReading
            defer {
                try? terminalReader?.close()
                try? terminalWriter?.close()
            }
            try lock.withLock {
                if cancelled { throw CancellationError() }
                try child.run()
                process = child
            }
            if !usePTY && !mergeStandardError {
                stderrDrain.enter()
                DispatchQueue.global().async {
                    defer { stderrDrain.leave() }
                    var bytes = [UInt8](repeating: 0, count: 16 * 1024)
                    while true {
                        let count = Darwin.read(errorPipe.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { break }
                        stderr.append(Data(bytes.prefix(count)))
                    }
                }
            }
            // Only the child retains the slave FD; closing ours permits EOF/EIO.
            try? terminalWriter?.close()
            let timer: DispatchSourceTimer? = timeout.map { interval in
                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + interval)
                timer.setEventHandler { Self.stop(child) }
                timer.resume()
                return timer
            }
            defer { timer?.cancel() }
            var captured = Data()
            var decoder = UTF8OutputDecoder()
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            var readError: Int32?
            while true {
                let count = Darwin.read(reader.fileDescriptor, &bytes, bytes.count)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    // A closed PTY reports EIO instead of a pipe's EOF.
                    if !usePTY || errno != EIO { readError = errno }
                    break
                }
                let data = Data(bytes.prefix(count))
                captured.append(data)
                if captured.count > captureLimit { captured.removeFirst(captured.count - captureLimit) }
                let text = decoder.consume(data)
                if !text.isEmpty { output(text) }
            }
            let tail = decoder.finish()
            if !tail.isEmpty { output(tail) }
            if readError != nil { Self.stop(child) }
            child.waitUntilExit()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                stderrDrain.notify(queue: .global()) { continuation.resume() }
            }
            let wasCancelled = lock.withLock { process = nil; return cancelled }
            if wasCancelled { throw CancellationError() }
            if let readError { throw POSIXError(POSIXErrorCode(rawValue: readError) ?? .EIO) }
            let result = String(decoding: captured, as: UTF8.self)
            guard child.terminationStatus == 0 else {
                throw RunnerError.message("\(URL(fileURLWithPath: executable).lastPathComponent) exited with status \(child.terminationStatus).\n\((result + stderr.text).suffix(4000))")
            }
            return result
        }.value
    }
}

/// Preserve multibyte characters when a pipe or terminal splits UTF-8 output.
struct UTF8OutputDecoder {
    private var pending = Data()
    mutating func consume(_ data: Data) -> String {
        pending.append(data)
        let bytes = Array(pending.suffix(4))
        var retained = 0
        if let lead = bytes.lastIndex(where: { $0 & 0xC0 != 0x80 }) {
            let first = bytes[lead]
            let length = first & 0xE0 == 0xC0 ? 2 : first & 0xF0 == 0xE0 ? 3 : first & 0xF8 == 0xF0 ? 4 : 1
            let present = bytes.count - lead
            if present < length { retained = present }
        }
        let result = String(decoding: pending.prefix(pending.count - retained), as: UTF8.self)
        pending = Data(pending.suffix(retained))
        return result
    }
    mutating func finish() -> String { defer { pending.removeAll() }; return String(decoding: pending, as: UTF8.self) }
}

/// A bounded bridge between pipe reading and throttled UI updates.
final class CommandOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ chunk: String) {
        lock.withLock {
            text += chunk
            if text.count > 1_000_000 { text = String(text.suffix(1_000_000)) }
        }
    }
    func drain() -> String { lock.withLock { let result = text; text = ""; return result } }
}

private final class CommandStderrCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > 4000 { data.removeFirst(data.count - 4000) }
        }
    }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
