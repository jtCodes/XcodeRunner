import Foundation
import CoreServices
import CryptoKit
import Darwin

final class ProjectWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    convenience init(root: String, onChange: @escaping () -> Void) {
        self.init(roots: [root], onChange: onChange)
    }
    init(roots: [String], onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<ProjectWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }, &context, roots.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot))
        if let stream { FSEventStreamSetDispatchQueue(stream, .main); FSEventStreamStart(stream) }
    }
    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}

enum SourceSnapshot {
    static let ignored: Set<String> = [".git", ".build", "build", "DerivedData", "node_modules", ".swiftpm", "xcuserdata", ".DS_Store"]

    static func capture(root: String) throws -> [String: String] {
        guard let resolved = realpath(root, nil) else { throw RunnerError.message("Project folder is unavailable: \(root)") }
        defer { free(resolved) }
        let rootURL = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RunnerError.message("Project folder is unavailable: \(root)")
        }
        var scanError: Error?
        guard let enumerator = FileManager.default.enumerator(at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [], errorHandler: { _, error in scanError = error; return false }) else {
            throw RunnerError.message("Cannot read project folder.")
        }
        var result: [String: String] = [:]
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { continue }
            if ignored.contains(file.lastPathComponent) {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hasher.update(data: data) }
            let prefix = rootURL.path + "/"
            guard file.path.hasPrefix(prefix) else { throw RunnerError.message("Cannot determine relative path for \(file.path)") }
            let key = String(file.path.dropFirst(prefix.count))
            result[key] = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        if let scanError { throw scanError }
        return result
    }

    static func changes(current: [String: String], baseline: [String: String]?) -> [FileChange] {
        guard let baseline else { return [] }
        return Set(current.keys).union(baseline.keys).sorted().compactMap { path in
            guard current[path] != baseline[path] else { return nil }
            return FileChange(path: path, kind: baseline[path] == nil ? "Added" : current[path] == nil ? "Deleted" : "Modified")
        }
    }
}
