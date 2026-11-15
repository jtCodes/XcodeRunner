import Foundation

enum DiagnosticSeverity: String, Sendable { case warning, error }
enum DiagnosticFilter: String, CaseIterable { case all = "All", errors = "Errors", warnings = "Warnings" }

struct IssueNavigationRequest {
    let id = UUID()
    let projectID: UUID
    let filter: DiagnosticFilter
}

struct BuildDiagnostic: Identifiable, Equatable, Sendable {
    let severity: DiagnosticSeverity
    let message: String
    var file: String?
    var line: Int?
    var column: Int?
    var id: String { "\(severity.rawValue)|\(file ?? "")|\(line ?? 0)|\(column ?? 0)|\(message)" }
    var locationLabel: String? {
        guard let file else { return nil }
        return URL(fileURLWithPath: file).lastPathComponent + (line.map { ":\($0)" } ?? "") + (column.map { ":\($0)" } ?? "")
    }
    func sourceURL(root: String) -> URL? {
        guard let file else { return nil }
        if file.hasPrefix("file://"), let url = URL(string: file), url.isFileURL { return url.standardizedFileURL }
        let path = (file as NSString).expandingTildeInPath
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return URL(fileURLWithPath: root).appendingPathComponent(path).standardizedFileURL
    }
    private static let located = try! NSRegularExpression(pattern: #"^(.+?):([0-9]+)(?::([0-9]+))?:\s*(warning|error|fatal error):\s*(.+)$"#)
    private static let fileOnly = try! NSRegularExpression(pattern: #"^(.+\.(?:xcodeproj|xcworkspace|swift|m|mm|c|h|plist|entitlements)):\s*(warning|error|fatal error):\s*(.+)$"#)
    private static let general = try! NSRegularExpression(pattern: #"^(?:(?:xcodebuild|swiftc?|clang|ld|codesign):\s*)?(warning|error|fatal error):\s*(.+)$"#)
    private static let ansi = try! NSRegularExpression(pattern: "\u{001B}\\[[0-?]*[ -/]*[@-~]")
    static func parse(_ raw: String) -> Self? {
        let clean = ansi.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
        let text = clean as NSString
        let range = NSRange(location: 0, length: text.length)
        if let match = located.firstMatch(in: clean, range: range) {
            return Self(severity: text.substring(with: match.range(at: 4)) == "warning" ? .warning : .error,
                message: text.substring(with: match.range(at: 5)), file: text.substring(with: match.range(at: 1)),
                line: Int(text.substring(with: match.range(at: 2))),
                column: match.range(at: 3).location == NSNotFound ? nil : Int(text.substring(with: match.range(at: 3))))
        }
        if let match = fileOnly.firstMatch(in: clean, range: range) {
            return Self(severity: text.substring(with: match.range(at: 2)) == "warning" ? .warning : .error,
                message: text.substring(with: match.range(at: 3)), file: text.substring(with: match.range(at: 1)))
        }
        if let match = general.firstMatch(in: clean, range: range) {
            return Self(severity: text.substring(with: match.range(at: 1)) == "warning" ? .warning : .error,
                message: text.substring(with: match.range(at: 2)))
        }
        return nil
    }
}
