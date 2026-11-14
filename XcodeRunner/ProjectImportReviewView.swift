import SwiftUI

struct ProjectImportReviewView: View {
    let review: ProjectImportReview
    let cancel: () -> Void
    let confirm: (Set<String>) -> Void
    @State private var selectedPaths: Set<String>

    init(review: ProjectImportReview, cancel: @escaping () -> Void, confirm: @escaping (Set<String>) -> Void) {
        self.review = review; self.cancel = cancel; self.confirm = confirm
        _selectedPaths = State(initialValue: Set(review.candidates.map(\.path)))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose Projects to Import").font(.title2.bold())
            Text("All projects start selected. Uncheck any you want to leave out.")
                .foregroundStyle(.secondary)
            HStack {
                Text("\(selectedPaths.count) of \(review.candidates.count) selected").font(.callout)
                Spacer()
                Button("Select All") { selectedPaths = Set(review.candidates.map(\.path)) }
                Button("Deselect All") { selectedPaths = [] }
            }
            List(review.candidates, id: \.path) { url in
                Toggle(isOn: Binding(get: { selectedPaths.contains(url.path) }, set: { checked in
                    if checked { selectedPaths.insert(url.path) } else { selectedPaths.remove(url.path) }
                })) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(url.deletingPathExtension().lastPathComponent).font(.headline)
                        Text((url.pathExtension == "xcworkspace" ? "Workspace · " : "Project · ") + url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }.padding(.vertical, 4)
                }.toggleStyle(.checkbox)
            }.listStyle(.inset).frame(height: 320)
            if review.alreadyAdded > 0 {
                Text("\(review.alreadyAdded) already added; their saved settings will be kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Import \(selectedPaths.count) Project\(selectedPaths.count == 1 ? "" : "s")") {
                    confirm(selectedPaths)
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(selectedPaths.isEmpty)
            }
        }.padding(24).frame(width: 600)
    }
}
