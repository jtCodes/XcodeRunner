import Foundation
import CryptoKit

/// Disk thumbnails survive relaunches. Only changed inputs require rediscovery.
struct ProjectIconCache: Sendable {
    struct CachedIcon: Sendable {
        let data: Data
        let fresh: Bool
    }
    private struct Entry: Codable {
        let data: Data
        let fingerprints: [String: String]
    }
    let directory: URL

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("XcodeRunner/ProjectIcons-v1", isDirectory: true)) {
        self.directory = directory
    }

    static func key(for project: TrackedProject) -> String {
        let fields = [project.containerPath, project.rootPath, project.scheme, project.configuration]
        let encoded = (try? JSONEncoder().encode(fields)) ?? Data()
        return digest(encoded)
    }

    func load(_ project: TrackedProject) -> CachedIcon? {
        guard let data = try? Data(contentsOf: file(project)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data), !entry.data.isEmpty else { return nil }
        return CachedIcon(data: entry.data, fresh: !entry.fingerprints.isEmpty && entry.fingerprints.allSatisfy {
            Self.fingerprint(URL(fileURLWithPath: $0.key)) == $0.value
        })
    }

    func save(_ data: Data, for project: TrackedProject, inputs: [URL]) throws {
        guard !data.isEmpty, !inputs.isEmpty else { return }
        let fingerprints = Dictionary(uniqueKeysWithValues: Set(inputs.map { $0.standardizedFileURL.path }).map {
            ($0, Self.fingerprint(URL(fileURLWithPath: $0)))
        })
        let entry = Entry(data: data, fingerprints: fingerprints)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(entry).write(to: file(project), options: .atomic)
    }

    static func projectInputs(_ project: TrackedProject, resolvedProject: URL?) -> [URL] {
        let container = URL(fileURLWithPath: project.containerPath)
        let containers = Set([container] + (resolvedProject.map { [$0] } ?? []))
        var inputs: [URL] = []
        for url in containers {
            inputs.append(url.appendingPathComponent(url.pathExtension == "xcodeproj" ? "project.pbxproj" : "contents.xcworkspacedata"))
            let shared = url.appendingPathComponent("xcshareddata/xcschemes")
            inputs.append(shared.appendingPathComponent(project.scheme + ".xcscheme"))
            let users = url.appendingPathComponent("xcuserdata")
            inputs.append(users)
            for user in (try? FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [] {
                inputs.append(user.appendingPathComponent("xcschemes/" + project.scheme + ".xcscheme"))
            }
        }
        return inputs
    }

    private func file(_ project: TrackedProject) -> URL { directory.appendingPathComponent(Self.key(for: project) + ".json") }

    private static func fingerprint(_ url: URL) -> String {
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]), values.isDirectory == true {
            return "directory:" + String(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        guard let data = try? Data(contentsOf: url) else { return "missing" }
        return digest(data)
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
