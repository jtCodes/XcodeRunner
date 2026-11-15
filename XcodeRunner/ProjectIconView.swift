import SwiftUI
import AppKit

@MainActor
private enum ProjectIconMemory {
    static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 100
        return cache
    }()
}

struct ProjectIconView: View {
    let project: TrackedProject
    @State private var icon: NSImage?
    @State private var loadedKey: String?

    init(project: TrackedProject) {
        self.project = project
        let key = ProjectIconCache.key(for: project)
        _icon = State(initialValue: ProjectIconMemory.images.object(forKey: key as NSString))
        _loadedKey = State(initialValue: key)
    }

    private func display(_ image: NSImage, key: String) {
        ProjectIconMemory.images.setObject(image, forKey: key as NSString)
        icon = image
    }

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: "app.dashed").font(.system(size: 24)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 32, height: 32).padding(.top, 2)
        .accessibilityHidden(true)
        .task(id: "\(project.id)|\(project.scheme)|\(project.configuration)") {
            let key = ProjectIconCache.key(for: project)
            if loadedKey != key { icon = nil; loadedKey = key }
            let cache = ProjectIconCache()
            let cached = await Task.detached(priority: .utility) { cache.load(project) }.value
            guard !Task.isCancelled else { return }
            if let cached, let image = NSImage(data: cached.data) {
                display(image, key: key)
                if cached.fresh { return }
            }
            // Keep a cached icon visible while stale metadata refreshes. A failed
            // read-only query never replaces good artwork with a placeholder.
            guard !project.scheme.isEmpty,
                  let settings = try? await XcodeTools.appBuildSettings(for: project), !Task.isCancelled else { return }
            let root = URL(fileURLWithPath: settings["SRCROOT"] as? String ?? project.rootPath)
            let name = settings["ASSETCATALOG_COMPILER_APPICON_NAME"] as? String ?? "AppIcon"
            let projectURL = (settings["PROJECT_FILE_PATH"] as? String).map { URL(fileURLWithPath: $0) }
            let target = settings["TARGET_NAME"] as? String
            let resolved = await Task.detached(priority: .utility) {
                ProjectAppIcon.resolve(root: root, name: name, project: projectURL, target: target)
            }.value
            guard !Task.isCancelled else { return }
            let inputs = ProjectIconCache.projectInputs(project, resolvedProject: projectURL)
            if let resolved, let image = NSImage(data: resolved.data) {
                display(image, key: key)
                await Task.detached(priority: .utility) {
                    try? cache.save(resolved.data, for: project, inputs: inputs + resolved.inputs)
                }.value
            } else if let directory = settings["TARGET_BUILD_DIR"] as? String,
                      let product = settings["FULL_PRODUCT_NAME"] as? String {
                let app = URL(fileURLWithPath: directory).appendingPathComponent(product)
                if FileManager.default.fileExists(atPath: app.path) {
                    let image = NSWorkspace.shared.icon(forFile: app.path)
                    display(image, key: key)
                    if let tiff = image.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        let resources = (try? FileManager.default.contentsOfDirectory(at: app.appendingPathComponent("Contents/Resources"), includingPropertiesForKeys: nil)) ?? []
                        let appInputs = [app, app.appendingPathComponent("Info.plist"), app.appendingPathComponent("Assets.car"), app.appendingPathComponent("Contents/Info.plist")] + resources.filter { ["icns", "car"].contains($0.pathExtension) }
                        await Task.detached(priority: .utility) {
                            try? cache.save(png, for: project, inputs: inputs + appInputs)
                        }.value
                    }
                }
            }
        }
    }
}
