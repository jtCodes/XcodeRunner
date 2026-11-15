import SwiftUI
import AppKit

struct RunIssuesView: View {
    let issues: [BuildDiagnostic]
    let rootPath: String
    @Binding var filter: DiagnosticFilter
    @State private var selectedIssue: BuildDiagnostic?
    private var filtered: [BuildDiagnostic] {
        issues.filter { filter == .all || ($0.severity == .error ? filter == .errors : filter == .warnings) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Issues", selection: $filter) {
                    ForEach(DiagnosticFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 240)
                Spacer()
                Text("\(filtered.count) issues").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).frame(height: 32)
            if filtered.isEmpty {
                Text(issues.isEmpty ? "No warnings or errors from this run." : "No \(filter.rawValue.lowercased()) in this run.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { issue in
                    Group {
                        if issue.file != nil {
                            Button { selectedIssue = issue } label: { issueRow(issue) }.buttonStyle(.plain)
                                .help("Preview \(issue.locationLabel ?? "source")")
                        } else { issueRow(issue).textSelection(.enabled) }
                    }
                    .contextMenu {
                        Button("Copy Diagnostic") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString((issue.locationLabel.map { $0 + "\n" } ?? "") + issue.message, forType: .string)
                        }
                    }
                }.listStyle(.inset)
            }
        }
        .sheet(item: $selectedIssue) { issue in DiagnosticSourceView(issue: issue, rootPath: rootPath) }
    }
    private func issueRow(_ issue: BuildDiagnostic) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(issue.severity == .error ? Color.red : Color.orange).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(issue.message).font(.callout).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                if let location = issue.locationLabel {
                    Label(location, systemImage: "doc.text").font(.caption).foregroundStyle(.tint)
                }
            }
            if issue.file != nil { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
        }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

private struct DiagnosticSourceView: View {
    let issue: BuildDiagnostic
    let rootPath: String
    @Environment(\.dismiss) private var dismiss
    @State private var source: String?
    @State private var message: String?
    private var url: URL? { issue.sourceURL(root: rootPath) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(issue.locationLabel ?? "Source").font(.headline)
                    Text(url?.path ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Open in Xcode") {
                    guard let url else { return }
                    Task {
                        do {
                            var args = ["xed"]
                            if let line = issue.line { args += ["--line", String(line)] }
                            _ = try await CommandRunner().run("/usr/bin/xcrun", args + [url.path], timeout: 30)
                        } catch { message = error.localizedDescription }
                    }
                }.disabled(url == nil)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(issue.message).font(.callout).textSelection(.enabled)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if let source {
                DiagnosticSourceTextView(text: source, line: issue.line).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if message == nil { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { Spacer() }
        }
        .padding(20).frame(width: 840, height: 560)
        .task(id: issue.id) {
            guard let url else { return }
            do {
                source = try await Task.detached {
                    var directory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else {
                        throw RunnerError.message("This source file is no longer available on disk.")
                    }
                    guard !directory.boolValue else { throw RunnerError.message("This location is a project or folder. Use Open in Xcode to inspect it.") }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
                    guard data.count <= 4 * 1024 * 1024 else { throw RunnerError.message("File is too large for preview. Use Open in Xcode.") }
                    guard let text = String(data: data, encoding: .utf8) else { throw RunnerError.message("This file is not UTF-8 text. Use Open in Xcode.") }
                    return text
                }.value
            } catch { message = error.localizedDescription }
        }
    }
}

private struct DiagnosticSourceTextView: NSViewRepresentable {
    let text: String
    let line: Int?
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        let view = NSTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .textColor
        view.textContainerInset = NSSize(width: 12, height: 12)
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        let source = text as NSString
        var offset = 0
        if let line, line > 1 {
            for _ in 1..<line {
                if offset >= source.length { break }
                offset = NSMaxRange(source.lineRange(for: NSRange(location: offset, length: 0)))
            }
        }
        let range = source.lineRange(for: NSRange(location: min(offset, source.length), length: 0))
        view.textStorage?.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.2), range: range)
        DispatchQueue.main.async { [weak view] in view?.scrollRangeToVisible(range) }
    }
}
