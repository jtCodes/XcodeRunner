import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Resolve the selected target's icon without compiling assets or building the app.
enum ProjectAppIcon {
    static func files(root: URL, name: String) -> [URL] {
        files(roots: [root], name: name)
    }

    static func files(roots: [URL], name: String) -> [URL] {
        guard !name.isEmpty else { return [] }
        var sets: Set<URL> = []
        for root in roots {
            guard let files = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in files {
                if Task.isCancelled { return [] }
                let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true || XcodeTools.importIgnored.contains(file.lastPathComponent) {
                    if values?.isDirectory == true { files.skipDescendants() }
                    continue
                }
                if file.pathExtension == "appiconset" {
                    files.skipDescendants()
                    if file.deletingPathExtension().lastPathComponent == name { sets.insert(file.standardizedFileURL) }
                } else if ["xcodeproj", "xcworkspace", "app", "framework", "xcframework"].contains(file.pathExtension) {
                    if values?.isDirectory == true { files.skipDescendants() }
                }
            }
        }
        // Multiple identically named catalogs are ambiguous; don't show another app's icon.
        guard sets.count == 1, let folder = sets.first,
              let data = try? Data(contentsOf: folder.appendingPathComponent("Contents.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = manifest["images"] as? [[String: Any]] else { return [] }
        return images.filter { $0["appearances"] == nil }.sorted { score($0) > score($1) }.compactMap {
            guard let filename = $0["filename"] as? String, !filename.isEmpty,
                  URL(fileURLWithPath: filename).lastPathComponent == filename else { return nil }
            let url = folder.appendingPathComponent(filename)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    /// Explicit resources and synchronized groups belong to the selected app,
    /// whereas dependency demo projects under SRCROOT do not.
    static func catalogRoots(project: URL, target: String, sourceRoot: URL) -> [URL] {
        guard let data = try? Data(contentsOf: project.appendingPathComponent("project.pbxproj")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["objects"] as? [String: [String: Any]] else { return [] }
        let matches = objects.values.filter { $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == target }
        guard matches.count == 1, let app = matches.first else { return [] }
        var parents: [String: String] = [:]
        for (id, object) in objects {
            for child in object["children"] as? [String] ?? [] { parents[child] = id }
        }
        func resolve(_ id: String, visited: Set<String> = []) -> URL? {
            guard !visited.contains(id), let object = objects[id] else { return nil }
            let path = object["path"] as? String ?? ""
            let tree = object["sourceTree"] as? String ?? "<group>"
            if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
            let base: URL
            if tree == "SOURCE_ROOT" { base = sourceRoot }
            else if tree == "<group>" {
                if let parent = parents[id] {
                    guard let resolved = resolve(parent, visited: visited.union([id])) else { return nil }
                    base = resolved
                } else { base = sourceRoot }
            } else { return nil }
            return path.isEmpty ? base : base.appendingPathComponent(path)
        }
        var roots: Set<URL> = []
        for phaseID in app["buildPhases"] as? [String] ?? [] {
            guard let phase = objects[phaseID], phase["isa"] as? String == "PBXResourcesBuildPhase" else { continue }
            for buildFile in phase["files"] as? [String] ?? [] {
                guard let ref = objects[buildFile]?["fileRef"] as? String,
                      let url = resolve(ref), url.pathExtension == "xcassets" else { continue }
                roots.insert(url.standardizedFileURL)
            }
        }
        for id in app["fileSystemSynchronizedGroups"] as? [String] ?? [] {
            if let url = resolve(id) { roots.insert(url.standardizedFileURL) }
        }
        return roots.sorted { $0.path < $1.path }
    }

    private static func score(_ image: [String: Any]) -> Double {
        let idiom = image["idiom"] as? String ?? ""
        let preferred = ["universal", "ios-marketing", "iphone", "ipad"].contains(idiom) ? 10_000.0 : 0
        let size = Double((image["size"] as? String ?? "0").split(separator: "x").first ?? "0") ?? 0
        let scale = Double((image["scale"] as? String ?? "1x").dropLast()) ?? 1
        return preferred + size * scale
    }

    struct ResolvedIcon: Sendable {
        let data: Data
        let inputs: [URL]
    }

    static func thumbnail(root: URL, name: String, project: URL? = nil, target: String? = nil) -> Data? {
        resolve(root: root, name: name, project: project, target: target)?.data
    }

    static func resolve(root: URL, name: String, project: URL? = nil, target: String? = nil) -> ResolvedIcon? {
        let catalogs: [URL]
        if let project, let target { catalogs = catalogRoots(project: project, target: target, sourceRoot: root) }
        else { catalogs = [] }
        for url in files(roots: catalogs.isEmpty ? [root] : catalogs, name: name) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 96
                  ] as CFDictionary) else { continue }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            if CGImageDestinationFinalize(destination) {
                return ResolvedIcon(data: data as Data,
                    inputs: [url, url.deletingLastPathComponent().appendingPathComponent("Contents.json")] + catalogs)
            }
        }
        return nil
    }
}
