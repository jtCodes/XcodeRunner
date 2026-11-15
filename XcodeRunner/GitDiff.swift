import Foundation

enum GitDiffScope: String, CaseIterable, Sendable {
    case all = "All Changes", unstaged = "Unstaged", staged = "Staged"
}

struct GitDiffLine: Sendable {
    enum Kind: Sendable { case context, addition, deletion, hunk, metadata }
    let kind: Kind
    let text: String
    var oldLine: Int? = nil
    var newLine: Int? = nil
}

struct GitDiffDocument: Identifiable, Sendable {
    let id = UUID()
    var lines: [GitDiffLine] = []
    var rawText = ""
    var message: String?
    var binary = false
    var additions: Int { lines.filter { $0.kind == .addition }.count }
    var deletions: Int { lines.filter { $0.kind == .deletion }.count }
}

enum GitDiff {
    private static let limit = 2 * 1024 * 1024

    static func load(root: String, change: FileChange, scope: GitDiffScope) async throws -> GitDiffDocument {
        let runner = CommandRunner()
        let base = ["--no-pager", "--no-optional-locks", "-C", root]
        let repository = try await runner.run("/usr/bin/git", base + ["rev-parse", "--show-toplevel"], mergeStandardError: false)
            .trimmingCharacters(in: .newlines)
        let head = try? await runner.run("/usr/bin/git", base + ["rev-parse", "--verify", "HEAD"], mergeStandardError: false)
        if change.gitStatus == "??" || (scope == .all && head == nil) {
            if scope == .staged { return GitDiffDocument(message: "This file has not been staged.") }
            return try await Task.detached(priority: .utility) {
                try addedFile(URL(fileURLWithPath: repository).appendingPathComponent(change.path))
            }.value
        }
        var args = ["--no-pager", "--no-optional-locks", "-C", repository, "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--find-renames", "--unified=3"]
        switch scope {
        case .all: args += ["HEAD"]
        case .staged: args += ["--cached"]
        case .unstaged: break
        }
        args += ["--"] + (change.originalPath.map { [$0] } ?? []) + [change.path]
        let output = try await runner.run("/usr/bin/git", args, timeout: 30,
            environment: ["GIT_LITERAL_PATHSPECS": "1"], captureLimit: limit, mergeStandardError: false)
        guard output.utf8.count < limit - 4 else {
            return GitDiffDocument(message: "This diff exceeds the 2 MB preview limit. Review it in your Git editor.")
        }
        return parse(output)
    }

    private static func addedFile(_ file: URL) throws -> GitDiffDocument {
        if !FileManager.default.fileExists(atPath: file.path) { return GitDiffDocument(message: "The file is no longer present in the working tree.") }
        let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        if values.isDirectory == true { return GitDiffDocument(message: "This is a directory or submodule. Review its repository separately.") }
        let data: Data
        if values.isSymbolicLink == true { data = Data(try FileManager.default.destinationOfSymbolicLink(atPath: file.path).utf8) }
        else {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            data = try handle.read(upToCount: limit + 1) ?? Data()
        }
        guard data.count <= limit else { return GitDiffDocument(message: "This file exceeds the 2 MB preview limit.") }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            return GitDiffDocument(message: "Binary or non-UTF-8 file added.", binary: true)
        }
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        if parts.isEmpty { return GitDiffDocument(message: "Empty file added.") }
        let patch = "@@ -0,0 +1,\(parts.count) @@\n" + parts.map { "+" + $0 }.joined(separator: "\n") + "\n"
        return parse(patch)
    }

    static func parse(_ text: String) -> GitDiffDocument {
        guard !text.isEmpty else { return GitDiffDocument(message: "No changes in this view.") }
        var document = GitDiffDocument(rawText: text)
        let header = try! NSRegularExpression(pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#)
        var old = 0, new = 0
        var inHunk = false
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        for raw in parts {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if let match = header.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let oldRange = Range(match.range(at: 1), in: line), let newRange = Range(match.range(at: 2), in: line) {
                old = Int(line[oldRange]) ?? 0; new = Int(line[newRange]) ?? 0; inHunk = true
                document.lines.append(GitDiffLine(kind: .hunk, text: line))
            } else if line.hasPrefix("diff --git ") || line.hasPrefix("@@@") {
                inHunk = false
                document.lines.append(GitDiffLine(kind: .metadata, text: line))
            } else if inHunk && line.hasPrefix("+") {
                document.lines.append(GitDiffLine(kind: .addition, text: String(line.dropFirst()), newLine: new)); new += 1
            } else if inHunk && line.hasPrefix("-") {
                document.lines.append(GitDiffLine(kind: .deletion, text: String(line.dropFirst()), oldLine: old)); old += 1
            } else if inHunk && line.hasPrefix(" ") {
                document.lines.append(GitDiffLine(kind: .context, text: String(line.dropFirst()), oldLine: old, newLine: new)); old += 1; new += 1
            } else {
                if line.hasPrefix("Binary files ") || line == "GIT binary patch" { document.binary = true }
                document.lines.append(GitDiffLine(kind: .metadata, text: line))
            }
        }
        return document
    }
}
