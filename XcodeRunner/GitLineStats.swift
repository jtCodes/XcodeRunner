import Foundation

struct GitLineStats: Sendable, Equatable {
    let additions: Int?
    let deletions: Int?
    var binary: Bool { additions == nil || deletions == nil }
}

enum GitLineCounts {
    /// --numstat -z keeps literal tabs/newlines in paths and emits a separate
    /// old/new path pair for renames instead of a display-only rename string.
    static func parse(_ output: String) throws -> [String: GitLineStats] {
        let records = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var result: [String: GitLineStats] = [:]
        var index = 0
        while index < records.count {
            let record = records[index]; index += 1
            if record.isEmpty && index == records.count { break }
            let columns = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3 else { throw RunnerError.message("Git returned invalid line counts.") }
            let additions = Int(columns[0]), deletions = Int(columns[1])
            guard (additions != nil && deletions != nil) || (columns[0] == "-" && columns[1] == "-") else {
                throw RunnerError.message("Git returned invalid line counts.")
            }
            let path: String
            if columns[2].isEmpty {
                guard index + 1 < records.count, !records[index + 1].isEmpty else {
                    throw RunnerError.message("Git returned an incomplete rename count.")
                }
                path = records[index + 1]; index += 2
            } else { path = String(columns[2]) }
            result[path] = GitLineStats(additions: additions, deletions: deletions)
        }
        return result
    }

    static func addedFile(_ file: URL) -> GitLineStats? {
        guard let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory != true else { return nil }
        let data: Data
        if values.isSymbolicLink == true {
            guard let link = try? FileManager.default.destinationOfSymbolicLink(atPath: file.path) else { return nil }
            data = Data(link.utf8)
        } else {
            guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
            defer { try? handle.close() }
            guard let bytes = try? handle.read(upToCount: 2 * 1024 * 1024 + 1) else { return nil }
            data = bytes
        }
        if data.contains(0) { return GitLineStats(additions: nil, deletions: nil) }
        guard data.count <= 2 * 1024 * 1024, String(data: data, encoding: .utf8) != nil else { return nil }
        let lines = data.reduce(0) { $0 + ($1 == 10 ? 1 : 0) } + (data.isEmpty || data.last == 10 ? 0 : 1)
        return GitLineStats(additions: lines, deletions: 0)
    }
}
