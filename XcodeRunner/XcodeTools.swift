import Foundation

enum XcodeTools {
    static func json(_ text: String) throws -> [String: Any] {
        // xcodebuild can print package-resolution notices before its JSON document.
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
            throw RunnerError.message("The Xcode tool did not return JSON.\n\(text.suffix(2000))")
        }
        guard let value = try JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] else {
            throw RunnerError.message("Unexpected Xcode tool response.")
        }
        return value
    }

    static let importIgnored = SourceSnapshot.ignored.union(["Pods", "Carthage", "CarthageBuild", "vendor"])

    static func discover(in selected: URL) throws -> [URL] {
        let selected = selected.standardizedFileURL.resolvingSymlinksInPath()
        if ["xcworkspace", "xcodeproj"].contains(selected.pathExtension) { return [selected] }
        var scanError: Error?
        guard let files = FileManager.default.enumerator(at: selected,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
            options: [.skipsHiddenFiles], errorHandler: { _, error in scanError = error; return false }) else {
            throw RunnerError.message("Cannot read the selected folder.")
        }
        var containers: [URL] = []
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
            // skipDescendants on a non-directory can skip the following sibling's
            // contents with Foundation's enumerator. Symlinks are never traversed.
            if values.isSymbolicLink == true { continue }
            if importIgnored.contains(file.lastPathComponent) {
                if values.isDirectory == true { files.skipDescendants() }
                continue
            }
            if values.isDirectory == true && ["xcworkspace", "xcodeproj"].contains(file.pathExtension) {
                files.skipDescendants()
                containers.append(file.standardizedFileURL.resolvingSymlinksInPath())
            } else if values.isPackage == true { files.skipDescendants() }
        }
        if let scanError { throw scanError }
        return preferredContainers(containers)
    }

    static func preferredContainers(_ containers: [URL]) -> [URL] {
        let projects = Set(containers.filter { $0.pathExtension == "xcodeproj" })
        let workspaceMembers = Dictionary(uniqueKeysWithValues: Set(containers.filter { $0.pathExtension == "xcworkspace" }).map {
            ($0, workspaceProjects($0))
        })
        // A workspace is useful only when it actually contains a project.
        // Empty or broken same-name workspaces must never hide a valid project.
        let workspaces = workspaceMembers.keys.filter { workspaceMembers[$0]?.isEmpty == false }.sorted {
            let leftMatches = workspaceMembers[$0]!.contains($0.deletingPathExtension().appendingPathExtension("xcodeproj").path)
            let rightMatches = workspaceMembers[$1]!.contains($1.deletingPathExtension().appendingPathExtension("xcodeproj").path)
            if leftMatches != rightMatches { return leftMatches }
            if $0.pathComponents.count != $1.pathComponents.count { return $0.pathComponents.count < $1.pathComponents.count }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        var keptWorkspaces: [URL] = []
        var memberSets: Set<Set<String>> = []
        var coveredProjects: Set<String> = []
        for workspace in workspaces {
            let members = workspaceMembers[workspace]!
            guard memberSets.insert(members).inserted else { continue }
            keptWorkspaces.append(workspace)
            coveredProjects.formUnion(members)
        }
        return (keptWorkspaces + projects.filter { !coveredProjects.contains($0.path) })
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func containersToImport(_ candidates: [URL], saved: [URL], folderImport: Bool) -> [URL] {
        let savedPaths = Set(saved.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        var covered = savedPaths
        var savedWorkspaceMembers: Set<Set<String>> = []
        for workspace in saved where workspace.pathExtension == "xcworkspace" {
            let members = workspaceProjects(workspace)
            covered.formUnion(members)
            if !members.isEmpty { savedWorkspaceMembers.insert(members) }
        }
        var result: [URL] = []
        for candidate in candidates {
            let candidate = candidate.standardizedFileURL.resolvingSymlinksInPath()
            if covered.contains(candidate.path) { continue }
            if folderImport && candidate.pathExtension == "xcworkspace" {
                let members = workspaceProjects(candidate)
                if savedWorkspaceMembers.contains(members) { continue }
                // Preserve an explicitly saved project and its settings on re-import.
                if !members.isDisjoint(with: savedPaths) { continue }
            }
            result.append(candidate)
            covered.insert(candidate.path)
        }
        return result
    }

    static func workspaceProjects(_ workspace: URL) -> Set<String> {
        var visited: Set<String> = []
        return workspaceProjects(workspace, visited: &visited)
    }

    private static func workspaceProjects(_ workspace: URL, visited: inout Set<String>) -> Set<String> {
        let workspace = workspace.standardizedFileURL.resolvingSymlinksInPath()
        guard visited.insert(workspace.path).inserted,
              let data = try? Data(contentsOf: workspace.appendingPathComponent("contents.xcworkspacedata")) else { return [] }
        let references = WorkspaceReferences(root: workspace.deletingLastPathComponent())
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = references
        guard parser.parse() else { return [] }
        var projects: Set<String> = []
        for path in references.containers {
            let container = URL(fileURLWithPath: path)
            if container.pathExtension == "xcworkspace" {
                projects.formUnion(workspaceProjects(container, visited: &visited))
            } else {
                var directory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue { projects.insert(path) }
            }
        }
        return projects
    }

    static func schemes(for project: TrackedProject) async throws -> (schemes: [String], configurations: [String]) {
        let text = try await CommandRunner().run("/usr/bin/xcodebuild", project.containerArguments + ["-list", "-json"], directory: project.rootPath)
        let object = try json(text)
        let details = (object["workspace"] ?? object["project"]) as? [String: Any] ?? [:]
        let schemes = details["schemes"] as? [String] ?? []
        guard !schemes.isEmpty else { throw RunnerError.message("No schemes found. Share an app scheme in Xcode, then refresh schemes.") }
        return (schemes.sorted(), details["configurations"] as? [String] ?? ["Debug", "Release"])
    }

    static func devices() async throws -> [RunDestination] {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: path) }
        _ = try await CommandRunner().run("/usr/bin/xcrun", ["devicectl", "list", "devices", "--timeout", "20", "--json-output", path.path], timeout: 30)
        return try parseDevices(Data(contentsOf: path))
    }

    static func parseDevices(_ data: Data) throws -> [RunDestination] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let records = (object["result"] as? [String: Any])?["devices"] as? [[String: Any]] ?? []
        return records.compactMap { record in
            let legacyDevice = record["deviceProperties"] as? [String: Any] ?? [:]
            let legacyHardware = record["hardwareProperties"] as? [String: Any] ?? [:]
            let legacyConnection = record["connectionProperties"] as? [String: Any] ?? [:]
            let properties = record["properties"] as? [String: Any] ?? [:]
            let stateProperties = properties["state"] as? [String: Any] ?? legacyDevice
            let hardware = properties["hardware"] as? [String: Any] ?? legacyHardware
            let connection = properties["connection"] as? [String: Any] ?? legacyConnection
            guard let id = record["identifier"] as? String else { return nil }
            let platform = (hardware["platform"] as? String ?? "").lowercased()
            guard (platform == "ios" || platform == "ipados"), hardware["reality"] as? String != "simulated" else { return nil }
            let state = connection["state"] as? String ?? connection["tunnelState"] as? String ?? "unavailable"
            let paired = connection["pairingState"] as? String == "paired"
            // Paired network devices establish their tunnel on demand. A disconnected
            // tunnel alone does not mean the device is unavailable for a run.
            let available = state == "connected" || paired
            return RunDestination(id: id, name: stateProperties["name"] as? String ?? "iPhone / iPad", kind: .device,
                available: available, detail: state == "connected" ? "Connected" : paired ? "Paired · connects on run" : "Unavailable")
        }
    }

    static func simulators() async throws -> [RunDestination] {
        let text = try await CommandRunner().run("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "--json"], timeout: 30)
        let groups = try json(text)["devices"] as? [String: [[String: Any]]] ?? [:]
        return groups.filter { $0.key.contains("iOS") }.flatMap { runtime, records in
            records.compactMap { record -> RunDestination? in
                guard let id = record["udid"] as? String, record["isAvailable"] as? Bool == true else { return nil }
                return RunDestination(id: id, name: record["name"] as? String ?? "Simulator", kind: .simulator,
                    available: true, detail: runtime.components(separatedBy: ".").last ?? runtime)
            }
        }
    }

    static func appProduct(settingsText: String) throws -> (path: String, bundleID: String) {
        guard let start = settingsText.firstIndex(of: "["), let end = settingsText.lastIndex(of: "]"),
              let rows = try JSONSerialization.jsonObject(with: Data(settingsText[start...end].utf8)) as? [[String: Any]] else {
            throw RunnerError.message("Cannot read build product settings.")
        }
        let apps = rows.compactMap { $0["buildSettings"] as? [String: Any] }.filter {
            ($0["WRAPPER_EXTENSION"] as? String) == "app" && ($0["PRODUCT_TYPE"] as? String) == "com.apple.product-type.application"
        }
        guard apps.count == 1, let app = apps.first,
              let directory = app["TARGET_BUILD_DIR"] as? String,
              let product = app["FULL_PRODUCT_NAME"] as? String,
              let bundleID = app["PRODUCT_BUNDLE_IDENTIFIER"] as? String else {
            throw RunnerError.message("Choose a scheme containing exactly one runnable app target.")
        }
        return (URL(fileURLWithPath: directory).appendingPathComponent(product).path, bundleID)
    }
}

private final class WorkspaceReferences: NSObject, XMLParserDelegate {
    let root: URL
    var groups: [URL] = []
    var containers: Set<String> = []
    init(root: URL) { self.root = root }
    private func resolve(_ location: String) -> URL? {
        guard let colon = location.firstIndex(of: ":") else { return nil }
        let kind = String(location[..<colon])
        let path = String(location[location.index(after: colon)...])
        switch kind {
        case "group": return (groups.last ?? root).appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        case "container": return root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        case "absolute": return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        default: return nil
        }
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if elementName == "Group" { groups.append(resolve(attributes["location"] ?? "group:") ?? groups.last ?? root) }
        if elementName == "FileRef", let location = attributes["location"], let file = resolve(location), ["xcodeproj", "xcworkspace"].contains(file.pathExtension) {
            containers.insert(file.path)
        }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "Group", !groups.isEmpty { groups.removeLast() }
    }
}
