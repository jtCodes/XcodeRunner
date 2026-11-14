import Foundation

struct TrackedProject: Identifiable, Codable, Sendable {
    var id = UUID()
    var containerPath: String
    var rootPath: String
    var schemes: [String] = []
    var scheme = ""
    var configurations = ["Debug", "Release"]
    var configuration = "Debug"
    var destinationID = ""
    var lastSuccess: Date?
    var baseline: [String: String]?
    var lastBundleID: String?
    var lastDestinationID: String?
    var lastRunSettings: String?
    var name: String { URL(fileURLWithPath: containerPath).deletingPathExtension().lastPathComponent }
    var containerArguments: [String] {
        [containerPath.hasSuffix(".xcworkspace") ? "-workspace" : "-project", containerPath]
    }
    var settingsKey: String { "\(scheme)|\(configuration)|\(destinationID)" }
}

struct RunDestination: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case device, simulator }
    var id: String
    var name: String
    var kind: Kind
    var available: Bool
    var detail: String
    var label: String { name + (kind == .simulator ? " · Simulator" : "") + (available ? "" : " · Unavailable") }
    static func ordered(_ destinations: [Self]) -> [Self] {
        destinations.sorted {
            if $0.kind != $1.kind { return $0.kind == .device }
            if $0.available != $1.available { return $0.available }
            let comparison = $0.name.localizedStandardCompare($1.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            let detailOrder = $0.detail.localizedStandardCompare($1.detail)
            return detailOrder == .orderedSame ? $0.id < $1.id : detailOrder == .orderedAscending
        }
    }
}

struct FileChange: Identifiable, Sendable {
    var path: String
    var kind: String
    var id: String { path }
}

enum RunnerError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

struct ProjectImportReview: Identifiable {
    let id = UUID()
    let candidates: [URL]
    let alreadyAdded: Int
}
