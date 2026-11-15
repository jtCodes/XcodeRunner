import SwiftUI
import AppKit

struct ProjectOutputView: View {
    @ObservedObject var store: RunnerStore
    let projectID: UUID
    @State private var tab = "build"
    @AppStorage("XcodeRunner.outputVisible") private var expanded = true
    @AppStorage("XcodeRunner.outputHeight") private var savedHeight = 270.0
    let maximumContentHeight: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragStartHeight: CGFloat?
    @State private var dragHeight: CGFloat?
    @State private var hoveringDivider = false
    private var contentHeight: CGFloat { min(max(120, savedHeight), maximumContentHeight) }
    private var displayedHeight: CGFloat { dragHeight ?? (expanded ? contentHeight : 0) }
    private var collapseAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.2) }
    @State private var issueFilter: DiagnosticFilter = .all

    var body: some View {
        VStack(spacing: 0) {
            resizeHandle
            HStack(spacing: 12) {
                Picker("Output", selection: Binding(get: { tab }, set: { tab = $0; expanded = true })) {
                    Text("Build Output").tag("build")
                    Text("App Console").tag("console")
                    Text("Issues (\(store.diagnostics[projectID]?.count ?? 0))").tag("issues")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 360)
                Spacer()
                Button { expanded.toggle() } label: {
                    Image(systemName: "rectangle.bottomthird.inset.filled")
                        .foregroundStyle(expanded ? Color.accentColor : Color.secondary)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Collapse output (⇧⌘Y)" : "Expand output (⇧⌘Y)")
                .accessibilityLabel(expanded ? "Collapse output" : "Expand output")
            }.padding(.horizontal, 20).padding(.vertical, 6)
                Group {
                    if tab == "issues" {
                        RunIssuesView(issues: store.diagnostics[projectID] ?? [],
                            rootPath: store.projects.first { $0.id == projectID }?.rootPath ?? "",
                            filter: $issueFilter)
                    } else if tab == "console" {
                        if let console = store.consoles[projectID] {
                            LiveConsoleView(console: console).id(console.id)
                        } else {
                            Text("Run the app to connect its live console.")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else { buildOutput }
                }
                .frame(height: max(120, displayedHeight))
                .frame(height: displayedHeight, alignment: .top)
                .clipped()
                .allowsHitTesting(expanded || dragHeight != nil)
                .accessibilityHidden(!expanded)
        }
        .animation(collapseAnimation, value: expanded)
        .onChange(of: store.issueNavigation?.id) { _, _ in
            guard let request = store.issueNavigation, request.projectID == projectID else { return }
            issueFilter = request.filter; tab = "issues"; expanded = true
        }
        .onAppear {
            if store.statuses[projectID] == "Failed", store.diagnostics[projectID]?.isEmpty == false {
                issueFilter = .errors; tab = "issues"
            } else if store.consoles[projectID] != nil && store.activeID != projectID { tab = "console" }
        }
        .onChange(of: store.consoles[projectID]?.id) { _, id in
            if id != nil { tab = "console" }
        }
        .onChange(of: store.activeID) { _, active in
            if active == projectID { tab = "build" }
        }
    }
    private var resizeHandle: some View {
        Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.3))
            .frame(height: 6)
            .overlay(Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1), alignment: .top)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != hoveringDivider else { return }
                hoveringDivider = inside
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                if hoveringDivider { NSCursor.pop(); hoveringDivider = false }
                dragStartHeight = nil; dragHeight = nil
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartHeight == nil { dragStartHeight = expanded ? contentHeight : 0 }
                    dragHeight = min(maximumContentHeight, max(0, (dragStartHeight ?? 0) - value.translation.height))
                }
                .onEnded { value in
                    let proposed = (dragStartHeight ?? (expanded ? contentHeight : 0)) - value.translation.height
                    withAnimation(collapseAnimation) {
                        if proposed < 60 {
                            // Keep the last expanded height so reopening restores it.
                            expanded = false
                        } else {
                            savedHeight = min(maximumContentHeight, max(120, proposed))
                            expanded = true
                        }
                        dragHeight = nil; dragStartHeight = nil
                    }
                })
            .onTapGesture(count: 2) {
                withAnimation(collapseAnimation) { savedHeight = 270; expanded = true }
            }
            .accessibilityElement()
            .accessibilityLabel("Resize output panel")
            .accessibilityValue(expanded ? "\(Int(contentHeight)) points" : "Collapsed")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    if !expanded { expanded = true }
                    else { savedHeight = min(maximumContentHeight, contentHeight + 40) }
                case .decrement:
                    if contentHeight <= 120 { expanded = false }
                    else { savedHeight = max(120, contentHeight - 40) }
                @unknown default: break
                }
            }
    }

    private var buildOutput: some View {
        LogOutputView(text: store.logs[projectID] ?? "", status: "Build & deployment logs", symbol: "hammer",
            live: store.activeID == projectID, placeholder: "Build and deployment output will appear here.\nPress Run or ⌘R to begin.")
            .id(store.runIDs[projectID])
    }
}

private struct LiveConsoleView: View {
    @ObservedObject var console: AppConsoleSession
    var body: some View {
        LogOutputView(text: console.text, status: console.status, symbol: console.isRunning ? "waveform" : "circle",
            live: console.isRunning, placeholder: "Waiting for app output…", clear: console.clear, disconnect: console.stop)
    }
}
