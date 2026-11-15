import Foundation

enum RunPhase: Int, CaseIterable, Sendable {
    case preparing, building, installing, launching
    var label: String {
        switch self {
        case .preparing: return "Prepare"
        case .building: return "Build"
        case .installing: return "Install"
        case .launching: return "Launch"
        }
    }
}

struct BuildProgress: Sendable {
    var phase: RunPhase = .preparing
    var activity = "Reading project files"
    var activities = 0
    var warnings = 0
    var errors = 0
    var launchOnly = false
    var lastOutput = Date()
}

/// xcodebuild does not expose a stable total-task count in its text stream.
/// Report actual activities and phases instead of inventing a percentage.
struct BuildOutputParser {
    private var pending = ""
    private var diagnosticIDs: Set<String> = []
    private(set) var diagnostics: [BuildDiagnostic] = []
    var progress = BuildProgress(phase: .building, activity: "Preparing build")

    mutating func consume(_ text: String) {
        pending += text
        let lines = pending.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        pending = String(lines.last ?? "")
        for line in lines.dropLast() { parse(String(line)) }
        // Avoid retaining an unbounded unterminated compiler diagnostic.
        if pending.count > 32_000 { pending = String(pending.suffix(16_000)) }
    }
    mutating func finish() { parse(pending); pending = "" }
    private mutating func parse(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        progress.lastOutput = Date()
        if let diagnostic = BuildDiagnostic.parse(line), diagnosticIDs.insert(diagnostic.id).inserted {
            diagnostics.append(diagnostic)
            if diagnostic.severity == .warning { progress.warnings += 1 } else { progress.errors += 1 }
        }
        let actions: [(String, String)] = [
            ("SwiftCompile ", "Compiling Swift"), ("CompileSwift ", "Compiling Swift"),
            ("SwiftEmitModule ", "Emitting Swift module"), ("CompileC ", "Compiling"),
            ("Ld ", "Linking"), ("CodeSign ", "Signing"),
            ("CompileAssetCatalog", "Compiling assets"), ("PhaseScriptExecution ", "Running build script"),
            ("ProcessInfoPlistFile ", "Processing Info.plist"), ("Copy ", "Copying"),
            ("CpResource ", "Copying resources"), ("Touch ", "Finishing product"),
            ("SwiftDriver ", "Preparing Swift compilation"), ("Resolve Package Graph", "Resolving packages"),
            ("ComputeTargetDependencyGraph", "Planning targets"), ("CreateBuildDescription", "Preparing build plan")
        ]
        guard let action = actions.first(where: { line.hasPrefix($0.0) }) else { return }
        progress.activities += 1
        let context = line.components(separatedBy: " (in target ")
        let details = context[0].dropFirst(action.0.count).trimmingCharacters(in: .whitespaces)
        let name: String
        if details.contains("/") { name = String(details.split(separator: "/").last ?? "") }
        else { name = details }
        let target = context.count > 1 ? " · " + context[1].components(separatedBy: " from project ")[0] : ""
        progress.activity = action.1 + (name.isEmpty ? "" : " · " + String(name.prefix(140))) + target
    }
}
