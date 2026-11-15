import Foundation

struct ProjectVersion: Sendable {
    let target: String
    let configuration: String
    let version: String
    let build: String
    let file: URL
    let original: Data
    let configurationID: String
    let editable: Bool
    var projectKeys: Set<String> = ["MARKETING_VERSION", "CURRENT_PROJECT_VERSION"]
    var plistFile: URL? = nil
    var plistOriginal: Data? = nil
    var plistKeys: Set<String> = []
    var unavailableReason: String? = nil
    var targetConfigurationIDs: [String] = []

    static func load(_ project: TrackedProject) async throws -> Self {
        let output = try await CommandRunner().run("/usr/bin/xcodebuild",
            project.containerArguments + ["-scheme", project.scheme, "-configuration", project.configuration,
                "-showBuildSettings", "-json"], directory: project.rootPath, mergeStandardError: false)
        let rows: [[String: Any]] = try ToolJSON.decode(output, context: "App version settings") { $0 as? [[String: Any]] }
        let apps = rows.compactMap { $0["buildSettings"] as? [String: Any] }.filter {
            $0["PRODUCT_TYPE"] as? String == "com.apple.product-type.application" && $0["WRAPPER_EXTENSION"] as? String == "app"
        }
        guard apps.count == 1, let settings = apps.first,
              let target = settings["TARGET_NAME"] as? String,
              let path = settings["PROJECT_FILE_PATH"] as? String else {
            throw RunnerError.message("Choose a scheme containing exactly one app target to view its version.")
        }
        return try read(settings: settings, target: target, path: path, configuration: project.configuration)
    }

    static func read(settings: [String: Any], target: String, path: String, configuration: String) throws -> Self {
        let file = URL(fileURLWithPath: path).appendingPathComponent("project.pbxproj")
        let original = try Data(contentsOf: file)
        let plist = try PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any]
        let objects = plist?["objects"] as? [String: [String: Any]] ?? [:]
        let targets = objects.values.filter { $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == target }
        guard targets.count == 1, let list = targets.first?["buildConfigurationList"] as? String,
              let ids = objects[list]?["buildConfigurations"] as? [String] else {
            throw RunnerError.message("Could not locate the app target's version settings.")
        }
        let matches = ids.filter { objects[$0]?["name"] as? String == configuration }
        guard matches.count == 1, let id = matches.first else {
            throw RunnerError.message("Could not locate the selected configuration.")
        }
        let local = objects[id]?["buildSettings"] as? [String: Any] ?? [:]
        var info: [String: Any] = [:]
        var infoFile: URL?
        var infoData: Data?
        var reason: String?
        let generated = settings["GENERATE_INFOPLIST_FILE"] as? String == "YES"
        if let plistPath = settings["INFOPLIST_FILE"] as? String, !plistPath.isEmpty {
            var resolved = plistPath
            for (key, value) in settings {
                guard let value = value as? String else { continue }
                resolved = resolved.replacingOccurrences(of: "$(\(key))", with: value)
                    .replacingOccurrences(of: "${\(key)}", with: value)
            }
            if !resolved.hasPrefix("/"), let root = settings["PROJECT_DIR"] as? String {
                resolved = URL(fileURLWithPath: root).appendingPathComponent(resolved).path
            }
            let url = URL(fileURLWithPath: resolved)
            if !resolved.contains("$("), !resolved.contains("${"), let data = try? Data(contentsOf: url),
               let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                info = dictionary; infoFile = url; infoData = data
            } else { reason = "The app's Info.plist could not be read. Check its path in Xcode." }
        }
        var projectKeys: Set<String> = []
        var infoKeys: Set<String> = []
        func field(_ setting: String, _ key: String) -> String {
            let override = "INFOPLIST_KEY_" + key
            if let value = settings[override] as? String {
                reason = "This app overrides \(key) through \(override). Edit that setting in Xcode."
                return value
            }
            if let literal = info[key] as? String,
               literal != "$(\(setting))", literal != "${\(setting)}" {
                guard valid(literal) else {
                    reason = "\(key) uses an unsupported expression or nonnumeric version. Edit it in Xcode."
                    return literal
                }
                infoKeys.insert(key)
                return literal
            }
            let value = settings[setting] as? String ?? ""
            guard (info[key] != nil || generated), valid(value), local[setting] as? String == value else {
                reason = "\(setting) is missing, inherited, or defined in an xcconfig. Edit its source in Xcode."
                return value
            }
            projectKeys.insert(setting)
            return value
        }
        let version = field("MARKETING_VERSION", "CFBundleShortVersionString")
        let build = field("CURRENT_PROJECT_VERSION", "CFBundleVersion")
        return Self(target: target, configuration: configuration, version: version, build: build,
                    file: file, original: original, configurationID: id, editable: reason == nil,
                    projectKeys: projectKeys, plistFile: infoFile, plistOriginal: infoData,
                    plistKeys: infoKeys, unavailableReason: reason, targetConfigurationIDs: ids)
    }

    static func valid(_ value: String) -> Bool {
        value.range(of: #"^[0-9]{1,9}(\.[0-9]{1,9}){0,2}$"#, options: .regularExpression) != nil
    }

    static func bumped(_ value: String, component: Int? = nil) -> String? {
        guard valid(value) else { return nil }
        var parts = value.split(separator: ".").compactMap { Int($0) }
        if let component {
            while parts.count < 3 { parts.append(0) }
            parts[component] += 1
            for index in parts.indices where index > component { parts[index] = 0 }
        } else { parts[parts.count - 1] += 1 }
        let result = parts.map(String.init).joined(separator: ".")
        return valid(result) ? result : nil
    }

    func editedSource(version: String, build: String, allConfigurations: Bool = false) throws -> Data {
        if allConfigurations, !projectKeys.isEmpty, !targetConfigurationIDs.isEmpty {
            var result = original
            for id in targetConfigurationIDs {
                let scoped = Self(target: target, configuration: configuration, version: self.version, build: self.build,
                    file: file, original: result, configurationID: id, editable: editable, projectKeys: projectKeys)
                result = try scoped.editedSource(version: version, build: build)
            }
            return result
        }
        guard editable, Self.valid(version), Self.valid(build), let source = String(data: original, encoding: .utf8) else {
            throw RunnerError.message("Use numeric versions with up to three components, such as 1.2.3 and 42.")
        }
        if projectKeys.isEmpty { return original }
        let objectPattern = "(?ms)^\\s*" + NSRegularExpression.escapedPattern(for: configurationID)
            + #"(?: /\*[^\n]*\*/)? = \{.*?^\s{2}\};"#
        let regex = try NSRegularExpression(pattern: objectPattern)
        let range = NSRange(source.startIndex..., in: source)
        let matches = regex.matches(in: source, range: range)
        guard matches.count == 1, let match = matches.first, let objectRange = Range(match.range, in: source) else {
            throw RunnerError.message("This project format cannot be safely edited. Change the version in Xcode.")
        }
        var object = String(source[objectRange])
        for (key, value) in [("MARKETING_VERSION", version), ("CURRENT_PROJECT_VERSION", build)] where projectKeys.contains(key) {
            let setting = try NSRegularExpression(pattern: "(?m)^(\\s*" + key + #" = )\"?[0-9.]+\"?;"#)
            guard setting.numberOfMatches(in: object, range: NSRange(object.startIndex..., in: object)) == 1 else {
                throw RunnerError.message("A target configuration has inherited or unsupported version settings. No changes were saved. Sync the version settings in Xcode.")
            }
            guard let match = setting.firstMatch(in: object, range: NSRange(object.startIndex..., in: object)),
                  let full = Range(match.range, in: object), let prefix = Range(match.range(at: 1), in: object) else {
                throw RunnerError.message("Could not locate version setting.")
            }
            object.replaceSubrange(full, with: String(object[prefix]) + value + ";")
        }
        let result = source.replacingCharacters(in: objectRange, with: object)
        let data = Data(result.utf8)
        _ = try PropertyListSerialization.propertyList(from: data, format: nil)
        return data
    }

    func editedPlist(version: String, build: String) throws -> Data? {
        guard let original = plistOriginal, !plistKeys.isEmpty else { return nil }
        guard Self.valid(version), Self.valid(build) else { throw RunnerError.message("Enter numeric version and build values.") }
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var info = try PropertyListSerialization.propertyList(from: original, format: &format) as? [String: Any] else {
            throw RunnerError.message("Could not read version plist.")
        }
        let values = [("CFBundleShortVersionString", version), ("CFBundleVersion", build)]
        if format == .xml, var source = String(data: original, encoding: .utf8) {
            for (key, value) in values where plistKeys.contains(key) {
                let regex = try NSRegularExpression(pattern: "(<key>" + key + "</key>\\s*<string>)[0-9.]+(</string>)")
                guard regex.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source)) == 1,
                      let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
                      let whole = Range(match.range, in: source), let prefix = Range(match.range(at: 1), in: source),
                      let suffix = Range(match.range(at: 2), in: source) else {
                    throw RunnerError.message("Unsupported Info.plist formatting. Edit the version in Xcode.")
                }
                source.replaceSubrange(whole, with: String(source[prefix]) + value + String(source[suffix]))
            }
            let result = Data(source.utf8)
            _ = try PropertyListSerialization.propertyList(from: result, format: nil)
            return result
        }
        for (key, value) in values where plistKeys.contains(key) { info[key] = value }
        return try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0)
    }

    var saveDescription: String {
        if projectKeys.isEmpty { return "Saves to Info.plist. This file may be shared by configurations or targets." }
        if plistKeys.isEmpty { return "Saves to all configurations of this app target, including the configuration used for Archive." }
        return "Saves to all configurations of this app target and Info.plist. The plist may be shared by other configurations or targets."
    }

    func syncForArchive() throws {
        // A prior bump may only have updated the Run configuration. Carry that
        // explicit version choice into the app target's Archive configuration.
        guard editable else { return }
        try save(version: version, build: build)
    }

    func save(version: String, build: String) throws {
        let data = try editedSource(version: version, build: build, allConfigurations: true)
        let infoData = try editedPlist(version: version, build: build)
        guard try Data(contentsOf: file) == original else {
            throw RunnerError.message("The project changed while editing. Close and reopen the version editor before saving.")
        }
        if let plistFile, let plistOriginal {
            guard try Data(contentsOf: plistFile) == plistOriginal else {
                throw RunnerError.message("Info.plist changed while editing. Close and reopen the version editor before saving.")
            }
        }
        // Write only files that changed. Roll the project back if the second write fails.
        if data != original { try data.write(to: file, options: .atomic) }
        do {
            if let infoData, let plistFile, infoData != plistOriginal { try infoData.write(to: plistFile, options: .atomic) }
        } catch {
            if data != original, (try? Data(contentsOf: file)) == data { try original.write(to: file, options: .atomic) }
            throw error
        }
    }
}
