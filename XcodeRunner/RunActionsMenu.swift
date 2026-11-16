import SwiftUI

struct RunActionsMenu: View {
    @ObservedObject var store: RunnerStore
    let project: TrackedProject
    @State private var presented = false

    var body: some View {
        Button { presented.toggle() } label: {
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Run and archive actions")
        .accessibilityLabel("Run and archive actions")
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                section("RUN")
                action("Launch Again", detail: "Launch the installed build", symbol: "arrow.clockwise",
                       enabled: store.activeID == nil && store.canLaunch(project)) { store.launchAgain(project) }
                Divider().padding(.horizontal, 10).padding(.vertical, 5)
                section("ARCHIVE")
                action("Archive & Open", detail: "Create an archive, then continue in Xcode", symbol: "archivebox",
                       shortcut: "⇧⌘B", enabled: store.canArchive(project)) { store.archive(project) }
                action("Open Last Archive", detail: "Reopen the saved archive in Xcode", symbol: "clock.arrow.circlepath",
                       enabled: project.lastArchivePath != nil) { store.openLastArchive(project) }
                    .help(project.lastArchivePath ?? "Create an archive first")
            }
            .padding(7).frame(width: 340)
            .modifier(RunMenuGlass())
            .padding(4)
            .presentationBackground(.clear)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 5).padding(.bottom, 2)
    }

    private func action(_ title: String, detail: String, symbol: String, shortcut: String? = nil,
                        enabled: Bool, perform: @escaping () -> Void) -> some View {
        RunMenuAction(title: title, detail: detail, symbol: symbol, shortcut: shortcut, enabled: enabled) {
            presented = false
            perform()
        }
    }
}

private struct RunMenuAction: View {
    let title: String
    let detail: String
    let symbol: String
    let shortcut: String?
    let enabled: Bool
    let perform: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                    .frame(width: 24, height: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let shortcut { Text(shortcut).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(hovered && enabled ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.45)
        .onHover { hovered = $0 }
    }
}

private struct RunMenuGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
