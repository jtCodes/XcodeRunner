import SwiftUI
import AppKit

struct GitReviewView: View {
    @ObservedObject var store: RunnerStore
    let project: TrackedProject
    let change: FileChange
    let close: () -> Void
    @State private var scope: GitDiffScope = .all
    @State private var document: GitDiffDocument?
    @State private var error: String?
    @State private var loading = false
    @State private var refresh = UUID()
    private var current: FileChange { store.changes[project.id]?.first { $0.path == change.path } ?? change }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Text(current.displayPath).font(.system(.callout, design: .monospaced)).lineLimit(2).truncationMode(.middle)
                        .help(current.displayPath)
                    Spacer(minLength: 0)
                    Button {
                        guard let text = document?.rawText else { return }
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                    } label: { Image(systemName: "doc.on.doc").frame(width: 22, height: 22) }
                        .help("Copy diff").disabled(document?.rawText.isEmpty != false)
                    Button(action: close) { Image(systemName: "xmark").frame(width: 22, height: 22) }.help("Close change review")
                }.buttonStyle(.plain)
                HStack(spacing: 8) {
                    Picker("Changes", selection: $scope) {
                        ForEach(GitDiffScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                    Button { refresh = UUID(); store.scan(project.id) } label: { Image(systemName: "arrow.clockwise").frame(width: 22, height: 22) }
                        .buttonStyle(.plain).help("Refresh diff")
                }
            }.padding(12)
            Divider()
            ZStack {
                if let error { message(error, symbol: "exclamationmark.triangle") }
                else if let document {
                    if let note = document.message { message(note, symbol: document.binary ? "doc" : "checkmark.circle") }
                    else { NativeDiffTextView(document: document, identity: change.path + scope.rawValue, swift: change.path.hasSuffix(".swift")) }
                }
                if loading { ProgressView().padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 12) {
                Text(current.detail).lineLimit(1).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("+\(document?.additions ?? 0)").foregroundStyle(.green)
                Text("−\(document?.deletions ?? 0)").foregroundStyle(.red)
            }.font(.caption.monospacedDigit()).padding(.horizontal, 12).frame(height: 30)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: "\(change.path)|\(scope.rawValue)|\(store.gitRevisions[project.id]?.uuidString ?? "")|\(refresh)") {
            loading = true; error = nil
            defer { loading = false }
            do {
                let result = try await GitDiff.load(root: project.rootPath, change: current, scope: scope)
                guard !Task.isCancelled else { return }
                document = result
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func message(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
