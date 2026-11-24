// Renders for the menu bar item, the popover in each state, and each Settings section.
// Same recipe as main.swift: never ordered front, drawn with `cacheDisplay(in:to:)`.
import AppKit
import GitHubPRWatchCore
import GitHubPRWatchUI
import SwiftUI

@MainActor
enum MenuBarRenders {
    static func renderAll(to folder: URL) async throws {
        let notifier = RecordingNotifier(status: .authorized)
        let signedInConfig = AppConfig(
            authMethod: .githubCLI, viewer: SampleData.viewer, watchedRepos: ["acme/web", "acme/api"], onboardingComplete: true
        )

        // Your move, with one PR that just turned ready (for the "Just now" tag).
        let api = StaticGitHubAPI(rateLimit: RateLimit(cost: 3, remaining: 4_812, resetAt: Date().addingTimeInterval(41 * 60)))
        var before = SampleData.pullRequests()
        if let i = before.firstIndex(where: { $0.id == "PR_ready" }) {
            before[i].checks?.checks[0] = CheckRun(name: "build", status: .inProgress, startedAt: Date().addingTimeInterval(-50 * 60))
        }
        await api.set(prs: before)
        let watching = PRStore(dependencies: .inMemory(api: api, config: signedInConfig, views: SampleData.views))
        await watching.refresh()
        await api.set(prs: SampleData.pullRequests())
        await watching.refresh()

        // Nothing needs you: only PRs that are someone else's move or in flight.
        let viewer = SampleData.viewer.login
        let calmPRs = SampleData.pullRequests().filter { PRClassifier.classify($0, viewer: viewer).lane != .yourMove }
        let calm = PRStore(dependencies: .inMemory(api: StaticGitHubAPI(prs: calmPRs), config: signedInConfig, views: SampleData.views))
        await calm.refresh()

        // Offline after a good poll: results stay, a banner says why.
        let offlineAPI = StaticGitHubAPI()
        let offline = PRStore(dependencies: .inMemory(api: offlineAPI, config: signedInConfig, views: SampleData.views))
        await offline.refresh()
        await offlineAPI.set(error: .offline)
        await offline.refresh()

        // Offline before any poll.
        let neverAPI = StaticGitHubAPI()
        await neverAPI.set(error: .offline)
        let offlineEmpty = PRStore(dependencies: .inMemory(api: neverAPI, config: signedInConfig, views: SampleData.views))
        await offlineEmpty.refresh()

        // Token rejected.
        let rejectedAPI = StaticGitHubAPI()
        await rejectedAPI.set(error: .unauthorized)
        let rejected = PRStore(dependencies: .inMemory(api: rejectedAPI, config: signedInConfig, views: SampleData.views))
        await rejected.refresh()

        // Signed out after setup, and before setup.
        let signedOut = PRStore(dependencies: .inMemory(api: StaticGitHubAPI(), config: AppConfig(watchedRepos: ["acme/web"], onboardingComplete: true)))
        let loading = PRStore(dependencies: .inMemory(api: StaticGitHubAPI(), config: signedInConfig, views: SampleData.views))

        for dark in [false, true] {
            try await render("popover-your-move", MenuBarPopoverView(store: watching), dark: dark, to: folder)
            try await render("popover-waiting-expanded", MenuBarPopoverView(store: watching, showWaiting: true), dark: dark, to: folder)
            try await render("popover-nothing-needs-you", MenuBarPopoverView(store: calm), dark: dark, to: folder)
            try await render("popover-offline", MenuBarPopoverView(store: offline), dark: dark, to: folder)
            try await render("popover-offline-no-data", MenuBarPopoverView(store: offlineEmpty), dark: dark, to: folder)
            try await render("popover-token-rejected", MenuBarPopoverView(store: rejected), dark: dark, to: folder)
            try await render("popover-signed-out", MenuBarPopoverView(store: signedOut), dark: dark, to: folder)
            try await render("popover-loading", MenuBarPopoverView(store: loading), dark: dark, to: folder)
        }
        // Each Settings section, as the whole window (see WindowRenders.swift).
        try await renderSettings(watching: watching, signedOut: signedOut, notifier: notifier)

        let states: [(String, MenuBarIndicator, String?)] = [
            ("calm", .calm, nil),
            ("badge", .needsYou(3), nil),
            ("label", .needsYou(3), "#1293 ready to merge"),
            ("offline", .offline, nil),
            ("signed-out", .signedOut, nil),
        ]
        for dark in [false, true] {
            for (name, indicator, label) in states {
                try writeMenuBar(MenuBarLabel.image(indicator: indicator, label: label), name: "menubar-\(name)", dark: dark, to: folder)
            }
        }
    }

    /// Draws `view` and waits for `.task`, `onAppear` and geometry-driven state to settle,
    /// then draws again.
    static func render<V: View>(_ name: String, _ view: V, size: CGSize? = nil, dark: Bool, to folder: URL) async throws {
        let root = view.background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.appearance = appearance
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size ?? host.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        for _ in 0..<3 {
            let fitting = size ?? host.fittingSize
            window.setContentSize(fitting)
            host.frame = CGRect(origin: .zero, size: fitting)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let file = folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
        try bitmap.representation(using: .png, properties: [:])?.write(to: file)
        print("wrote \(file.path)")
    }

    /// The template image on a strip of menu bar, tinted as macOS tints it, at 4×.
    static func writeMenuBar(_ image: NSImage, name: String, dark: Bool, to folder: URL) throws {
        let scale: CGFloat = 4
        let bar = NSSize(width: max(image.size.width + 24, 64), height: 24)
        let px = NSSize(width: bar.width * scale, height: bar.height * scale)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(px.width), pixelsHigh: Int(px.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        NSRect(origin: .zero, size: px).fill()

        // Tint: the template's alpha as a mask over the menu bar's text color.
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.88).set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let drawRect = NSRect(
            x: 12 * scale, y: (bar.height - image.size.height) / 2 * scale,
            width: image.size.width * scale, height: image.size.height * scale
        )
        tinted.draw(in: drawRect)
        NSGraphicsContext.restoreGraphicsState()
        let file = folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
        try bitmap.representation(using: .png, properties: [:])?.write(to: file)
        print("wrote \(file.path)")
    }
}
