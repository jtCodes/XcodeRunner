import Foundation
import CryptoKit

enum GitChanges {
    struct Snapshot: Sendable {
        let changes: [FileChange]
        let repository: String
        let gitDirectory: String
        let branch: String
        let fingerprint: String?
    }

    static func read(root: String) async throws -> Snapshot {
        let runner = CommandRunner()
        let base = ["--no-pager", "--no-optional-locks", "-C", root]
        let repository: String
        do {
            repository = try await runner.run("/usr/bin/git", base + ["rev-parse", "--show-toplevel"], mergeStandardError: false)
                .trimmingCharacters(in: .newlines)
        } catch { throw RunnerError.message("Git changes unavailable. This folder must belong to a readable Git repository.\n\(error.localizedDescription)") }
        let directory = try await runner.run("/usr/bin/git", base + ["rev-parse", "--absolute-git-dir"], mergeStandardError: false)
            .trimmingCharacters(in: .newlines)
        let output = try await runner.run("/usr/bin/git", base + ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "."], mergeStandardError: false)
        var changes = try parse(output)
        let head = (try? await runner.run("/usr/bin/git", base + ["rev-parse", "--verify", "HEAD"], mergeStandardError: false)) ?? "unborn"
        let symbolicBranch = (try? await runner.run("/usr/bin/git", base + ["symbolic-ref", "--quiet", "--short", "HEAD"], mergeStandardError: false))?
            .trimmingCharacters(in: .newlines)
        let branch = symbolicBranch.flatMap { $0.isEmpty ? nil : $0 }
            ?? (head == "unborn" ? "No branch" : "Detached " + head.trimmingCharacters(in: .newlines).prefix(8))
        if head != "unborn" {
            let statsOutput = try await runner.run("/usr/bin/git", base + ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--numstat", "-z", "HEAD", "--", "."], mergeStandardError: false)
            let stats = try GitLineCounts.parse(statsOutput)
            for index in changes.indices where changes[index].gitStatus != "??" {
                // Staged changes can cancel out unstaged changes relative to HEAD.
                changes[index].lineStats = stats[changes[index].path] ?? GitLineStats(additions: 0, deletions: 0)
            }
            // Git can pair identical deleted files with a rename differently
            // across the index and working tree. Scope each known rename to
            // its status paths so counts match that file's review precisely.
            for index in changes.indices {
                guard let original = changes[index].originalPath else { continue }
                let pair = try await runner.run("/usr/bin/git",
                    ["--no-pager", "--no-optional-locks", "-C", repository, "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--find-renames", "--numstat", "-z", "HEAD", "--", original, changes[index].path],
                    environment: ["GIT_LITERAL_PATHSPECS": "1"], mergeStandardError: false)
                let pairStats = try GitLineCounts.parse(pair)
                changes[index].lineStats = pairStats[changes[index].path] ?? GitLineStats(additions: 0, deletions: 0)
            }
        }
        let counted = changes
        changes = await Task.detached(priority: .utility) {
            var result = counted
            for index in result.indices {
                let file = URL(fileURLWithPath: repository).appendingPathComponent(result[index].path)
                result[index].lastModified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if result[index].gitStatus == "??" || head == "unborn" {
                    result[index].lineStats = GitLineCounts.addedFile(file)
                }
            }
            return result
        }.value
        let finalChanges = changes
        let fingerprint = try await Task.detached(priority: .utility) {
            try fingerprint(repository: repository, directory: directory, status: output, head: head, changes: finalChanges)
        }.value
        return Snapshot(changes: changes, repository: repository, gitDirectory: directory, branch: branch, fingerprint: fingerprint)
    }

    static func parse(_ output: String) throws -> [FileChange] {
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var result: [FileChange] = []
        var index = 0
        while index < records.count {
            let record = records[index]; index += 1
            guard record.count >= 4, record[record.index(record.startIndex, offsetBy: 2)] == " " else {
                throw RunnerError.message("Git returned an invalid status record.")
            }
            let status = String(record.prefix(2))
            let path = String(record.dropFirst(3))
            var original: String?
            if status.contains("R") || status.contains("C") {
                guard index < records.count else { throw RunnerError.message("Git returned an incomplete rename record.") }
                original = records[index]; index += 1
            }
            let kind: String
            if ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(status) { kind = "Conflict" }
            else if status == "??" { kind = "Untracked" }
            else if status.contains("R") { kind = "Renamed" }
            else if status.contains("C") { kind = "Copied" }
            else if status.contains("D") { kind = "Deleted" }
            else if status.contains("A") { kind = "Added" }
            else if status.contains("T") { kind = "Type changed" }
            else { kind = "Modified" }
            result.append(FileChange(path: path, kind: kind, originalPath: original, gitStatus: status))
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // Keep Launch Again's last-built-source check separate from the visible Git
    // count. Only changed files are hashed; never walk ignored dependency trees.
    private static func fingerprint(repository: String, directory: String, status: String, head: String, changes: [FileChange]) throws -> String? {
        var hasher = SHA256()
        hasher.update(data: Data((head + "\0" + status).utf8))
        let index = URL(fileURLWithPath: directory).appendingPathComponent("index")
        if let data = try? Data(contentsOf: index) { hasher.update(data: data) }
        for change in changes {
            try Task.checkCancellation()
            let file = URL(fileURLWithPath: repository).appendingPathComponent(change.path)
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]) else { continue }
            if values.isSymbolicLink == true {
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: file.path)
                hasher.update(data: Data(destination.utf8))
            } else if values.isDirectory == true {
                // A dirty submodule requires a build; don't mistake its status
                // text for proof that the installed product is current.
                return nil
            } else if values.isRegularFile == true {
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                    try Task.checkCancellation()
                    hasher.update(data: data)
                }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
