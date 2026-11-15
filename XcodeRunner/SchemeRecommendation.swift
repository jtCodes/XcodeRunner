import Foundation

enum SchemeRecommendation {
    static func choose(schemes: [String], project: TrackedProject) -> String? {
        let container = URL(fileURLWithPath: project.containerPath)
        let projects = container.pathExtension == "xcodeproj" ? Set([container.path]) : XcodeTools.workspaceProjects(container)
        var appTargets: Set<String> = []
        var launchable: Set<String> = []
        var containers = [container]
        for path in projects where !path.components(separatedBy: "/").contains(where: XcodeTools.importIgnored.contains) {
            let url = URL(fileURLWithPath: path)
            containers.append(url)
            if let data = try? Data(contentsOf: url.appendingPathComponent("project.pbxproj")),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let objects = plist["objects"] as? [String: [String: Any]] {
                for target in objects.values where target["isa"] as? String == "PBXNativeTarget"
                    && target["productType"] as? String == "com.apple.product-type.application" {
                    if let name = target["name"] as? String { appTargets.insert(name) }
                }
            }
        }
        for container in Set(containers) {
            var folders = [container.appendingPathComponent("xcshareddata/xcschemes")]
            let userData = container.appendingPathComponent("xcuserdata")
            for user in (try? FileManager.default.contentsOfDirectory(at: userData, includingPropertiesForKeys: nil)) ?? [] {
                folders.append(user.appendingPathComponent("xcschemes"))
            }
            for folder in folders {
                for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "xcscheme" {
                    guard let data = try? Data(contentsOf: file) else { continue }
                    let delegate = AppSchemeLaunchAction()
                    let parser = XMLParser(data: data)
                    parser.shouldResolveExternalEntities = false
                    parser.delegate = delegate
                    if parser.parse(), delegate.hasApp { launchable.insert(file.deletingPathExtension().lastPathComponent) }
                }
            }
        }
        let candidates = schemes.filter { launchable.contains($0) || appTargets.contains($0) }
        let containerName = normalized(container.deletingPathExtension().lastPathComponent)
        let rootName = normalized(URL(fileURLWithPath: project.rootPath).lastPathComponent)
        func score(_ scheme: String) -> Int {
            let name = normalized(scheme)
            var value = launchable.contains(scheme) ? 20 : 0
            if name == containerName { value += 100 }
            if name == rootName { value += 80 }
            if name.hasPrefix(containerName) { value += 10 }
            return value
        }
        return candidates.sorted {
            if score($0) != score($1) { return score($0) > score($1) }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }.first
    }
    private static func normalized(_ name: String) -> String { name.lowercased().filter { $0.isLetter || $0.isNumber } }
}

private final class AppSchemeLaunchAction: NSObject, XMLParserDelegate {
    var hasApp = false
    private var inLaunch = false
    private var inRunnable = false
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if name == "LaunchAction" { inLaunch = true }
        if name == "BuildableProductRunnable", inLaunch { inRunnable = true }
        if name == "BuildableReference", inRunnable, attributes["BuildableName"]?.hasSuffix(".app") == true { hasApp = true }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        if name == "BuildableProductRunnable" { inRunnable = false }
        if name == "LaunchAction" { inLaunch = false }
    }
}
