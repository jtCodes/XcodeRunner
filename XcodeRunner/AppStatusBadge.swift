import SwiftUI

struct ConsoleAppStatusBadge: View {
    @ObservedObject var console: AppConsoleSession
    var compact = false
    var body: some View { AppStatusBadge(state: console.appState, compact: compact) }
}

struct AppStatusBadge: View {
    let state: AppExecutionState
    var compact = false
    private var tint: Color {
        switch state {
        case .running: return .green
        case .starting, .waitingForUnlock: return .orange
        case .exited, .unknown: return .secondary
        }
    }
    var body: some View {
        HStack(spacing: 7) {
            if state == .waitingForUnlock { Image(systemName: "lock.fill").font(.caption) }
            else { Circle().fill(tint).frame(width: 8, height: 8) }
            Text(state.label).font(compact ? .caption.weight(.medium) : .callout.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 0 : 12).padding(.vertical, compact ? 0 : 6)
        .background(tint.opacity(compact ? 0 : 0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(compact ? 0 : 0.25)))
        .fixedSize()
        .help(state.detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.label)
        .accessibilityHint(state.detail)
    }
}

struct ProjectToolbarStatus: View {
    @ObservedObject var store: RunnerStore
    let project: TrackedProject
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(store.statuses[project.id] ?? "Ready to run")
                    .font(.caption.weight(.semibold)).lineLimit(1)
                if store.activeID == project.id, let start = store.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = max(0, Int(context.date.timeIntervalSince(start)))
                        Text("\(seconds / 60):\(String(format: "%02d", seconds % 60))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            if store.waitingForUnlockID == project.id {
                AppStatusBadge(state: .waitingForUnlock, compact: true)
            } else if let console = store.consoles[project.id], console.runSettingsKey == project.settingsKey {
                ConsoleAppStatusBadge(console: console, compact: true)
            } else { AppStatusBadge(state: .unknown, compact: true) }
        }
        .frame(minWidth: 130, maxWidth: 190, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .help(store.buildProgress[project.id]?.activity ?? "Run and app status")
    }
}
