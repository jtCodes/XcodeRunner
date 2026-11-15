import Foundation

/// Archive uses the scheme's Archive action/configuration, independent of the run device.
struct ArchivePlan: Sendable {
    let path: URL
    let arguments: [String]

    init(project: TrackedProject, archives: URL, date: Date = Date(), identifier: UUID = UUID()) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let folder = archives.appendingPathComponent(formatter.string(from: date), isDirectory: true)
        formatter.dateFormat = "HH-mm-ss"
        let name = project.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        path = folder.appendingPathComponent("\(name) \(formatter.string(from: date)) \(identifier.uuidString).xcarchive", isDirectory: true)
        arguments = project.containerArguments + ["-scheme", project.scheme, "-destination", "generic/platform=iOS",
            "-archivePath", path.path, "archive"]
    }

    func validate(expectedVersion: String? = nil, expectedBuild: String? = nil) throws {
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: path.appendingPathComponent("Info.plist")), format: nil) as? [String: Any]
        guard let properties = info?["ApplicationProperties"] as? [String: Any],
              let application = properties["ApplicationPath"] as? String,
              application.hasSuffix(".app"),
              FileManager.default.fileExists(atPath: path.appendingPathComponent("Products").appendingPathComponent(application).path) else {
            throw RunnerError.message("The scheme produced a generic archive instead of a distributable app archive. Check its Archive action and Skip Install settings in Xcode. Archive: \(path.path)")
        }
        if let expectedVersion, let expectedBuild {
            let appInfo = path.appendingPathComponent("Products").appendingPathComponent(application).appendingPathComponent("Info.plist")
            let product = try PropertyListSerialization.propertyList(from: Data(contentsOf: appInfo), format: nil) as? [String: Any]
            let actualVersion = product?["CFBundleShortVersionString"] as? String ?? "unknown"
            let actualBuild = product?["CFBundleVersion"] as? String ?? "unknown"
            guard actualVersion == expectedVersion, actualBuild == expectedBuild else {
                throw RunnerError.message("Archive version mismatch: expected \(expectedVersion) (\(expectedBuild)), but built \(actualVersion) (\(actualBuild)). Open Edit Version and Save & Sync, then archive again. Archive saved at \(path.path)")
            }
        }
    }
}
