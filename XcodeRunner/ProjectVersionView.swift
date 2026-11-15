import SwiftUI

struct ProjectVersionView: View {
    let project: TrackedProject
    @State private var value: ProjectVersion?
    @State private var error: String?
    @State private var loading = false
    @State private var editing = false
    @State private var refresh = UUID()

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
          HStack(spacing: 8) {
            if loading { ProgressView().controlSize(.small); Text("Reading version…") }
            else if let value {
                Text("v\(value.version.isEmpty ? "—" : value.version) (\(value.build.isEmpty ? "—" : value.build))").monospacedDigit().lineLimit(1)
                    .help("App version \(value.version), build \(value.build)")
                Button { editing = true } label: { Image(systemName: "square.and.pencil").frame(width: 20, height: 20) }
                    .buttonStyle(.plain).accessibilityLabel("Edit Version and Build")
                    .disabled(!value.editable)
                    .help(value.editable ? "Edit \(value.target) · \(value.configuration)" : value.unavailableReason ?? "Version editing unavailable")
            } else { Text(error ?? "Choose a scheme to read its version.").foregroundStyle(.secondary) }
            Button { refresh = UUID() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).disabled(loading || project.scheme.isEmpty).help("Refresh version")
          }
          if let reason = value?.unavailableReason {
              Text(reason).font(.caption).foregroundStyle(.secondary)
          }
        }
        .font(.caption)
        .task(id: "\(project.id)|\(project.scheme)|\(project.configuration)|\(refresh)") {
            value = nil; error = nil
            guard !project.scheme.isEmpty else { return }
            loading = true
            defer { loading = false }
            do {
                let result = try await ProjectVersion.load(project)
                guard !Task.isCancelled else { return }
                value = result
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .sheet(isPresented: $editing) {
            if let value { VersionEditor(value: value) { refresh = UUID() } }
        }
    }
}

private struct VersionEditor: View {
    let value: ProjectVersion
    let saved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var version: String
    @State private var build: String
    @State private var error: String?

    init(value: ProjectVersion, saved: @escaping () -> Void) {
        self.value = value; self.saved = saved
        _version = State(initialValue: value.version); _build = State(initialValue: value.build)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Version & Build").font(.title2.bold())
            Text("\(value.target) · \(value.configuration)").foregroundStyle(.secondary)
            Text(value.saveDescription).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Version", text: $version)
                ForEach(Array(["Major", "Minor", "Patch"].enumerated()), id: \.offset) { index, title in
                    Button(title) { if let next = ProjectVersion.bumped(version, component: index) { version = next } }
                        .disabled(!ProjectVersion.valid(version))
                }
            }
            HStack {
                TextField("Build", text: $build)
                Button("+1") { if let next = ProjectVersion.bumped(build) { build = next } }
                    .disabled(!ProjectVersion.valid(build))
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(value.targetConfigurationIDs.count > 1 && !value.projectKeys.isEmpty ? "Save & Sync" : "Save") {
                    do { try value.save(version: version, build: build); saved(); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
                    .disabled(!ProjectVersion.valid(version) || !ProjectVersion.valid(build) || (version == value.version && build == value.build && (value.targetConfigurationIDs.count <= 1 || value.projectKeys.isEmpty)))
            }
        }.padding(24).frame(width: 520)
    }
}
