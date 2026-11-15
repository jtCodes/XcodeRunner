import Foundation

extension XcodeTools {
    /// Read-only metadata query shared by the version editor and project icons.
    static func appBuildSettings(for project: TrackedProject) async throws -> [String: Any] {
        let output = try await CommandRunner().run("/usr/bin/xcodebuild",
            project.containerArguments + ["-scheme", project.scheme, "-configuration", project.configuration,
                "-showBuildSettings", "-json"], directory: project.rootPath, mergeStandardError: false)
        let rows: [[String: Any]] = try ToolJSON.decode(output, context: "App build settings") { $0 as? [[String: Any]] }
        let apps = rows.compactMap { $0["buildSettings"] as? [String: Any] }.filter {
            $0["PRODUCT_TYPE"] as? String == "com.apple.product-type.application" && $0["WRAPPER_EXTENSION"] as? String == "app"
        }
        guard apps.count == 1, let app = apps.first else {
            throw RunnerError.message("Choose a scheme containing exactly one app target.")
        }
        return app
    }
}
