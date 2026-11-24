// Draws the UI to PNG files with placeholder data, without showing a window or taking focus.
// Run with scripts/render.sh. Output goes to the folder given as the first argument.
//
// The recipe: activation policy `.prohibited`, each view in an NSHostingView inside an
// NSWindow that is never ordered front, drawn with `cacheDisplay(in:to:)`. Async state
// settles with `Task.sleep`, never by running the run loop.
import AppKit
import GitHubPRWatchCore
import GitHubPRWatchUI
import SwiftUI

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/renders", isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

@MainActor
func render<V: View>(_ name: String, _ view: V, size: CGSize? = nil, dark: Bool) throws {
    let root = view.background(Color(nsColor: .windowBackgroundColor))
    let host = NSHostingView(rootView: root)
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.appearance = appearance
    let fitting = size ?? host.fittingSize
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: fitting), styleMask: [.titled], backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = host
    host.frame = CGRect(origin: .zero, size: fitting)
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let file = outputDirectory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
    try bitmap.representation(using: .png, properties: [:])?.write(to: file)
    print("wrote \(file.path)")
}

@MainActor
func writeImage(_ image: NSImage, name: String) throws {
    let scale: CGFloat = 4
    let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    image.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    let file = outputDirectory.appendingPathComponent("\(name).png")
    try bitmap.representation(using: .png, properties: [:])?.write(to: file)
    print("wrote \(file.path)")
}

let notifier = RecordingNotifier()

// Onboarding before sign-in: the CLI is detected, the repo list is locked.
let signedOut = PRStore(dependencies: .inMemory(api: StaticGitHubAPI()))

// Onboarding after one click on the CLI login: repos load and suggestions are pre-checked.
let signedIn = PRStore(dependencies: .inMemory(api: StaticGitHubAPI()))
await signedIn.signInWithGitHubCLI()
await signedIn.loadRepoChoices()

// The lanes, after one poll of the sample PRs.
let watching = PRStore(dependencies: .inMemory(
    api: StaticGitHubAPI(),
    config: AppConfig(authMethod: .githubCLI, viewer: SampleData.viewer, watchedRepos: ["acme/web", "acme/api"], onboardingComplete: true),
    views: SampleData.views
))
await watching.refresh()
watching.selectedViewID = BuiltInViews.mineID

// The lanes in other states. Each is its own store so the states don't leak.
let watchingConfig = AppConfig(authMethod: .githubCLI, viewer: SampleData.viewer, watchedRepos: ["acme/web", "acme/api", "acme/infra"], onboardingComplete: true)
@MainActor func lanesStore(_ api: any GitHubAPI) -> PRStore {
    let store = PRStore(dependencies: .inMemory(api: api, config: watchingConfig, views: SampleData.views))
    store.selectedViewID = BuiltInViews.mineID
    return store
}

// CI just finished: #4826 was running at the first poll, then finished green and approved.
let finishingAPI = StaticGitHubAPI()
let justFinished = lanesStore(finishingAPI)
await justFinished.refresh()
await finishingAPI.set(prs: SampleData.pullRequests().map { pr in
    guard pr.id == "PR_running" else { return pr }
    var done = pr
    done.reviewDecision = .approved
    done.mergeStateStatus = .clean
    done.updatedAt = Date()
    let checks = done.checks?.checks ?? []
    done.checks?.checks = checks.map { check in
        var check = check
        check.status = .completed
        check.conclusion = .success
        check.completedAt = check.completedAt ?? Date().addingTimeInterval(-20)
        return check
    }
    return done
})
await justFinished.refresh()

// Nothing matches the view.
let emptyView = lanesStore(StaticGitHubAPI(prs: []))
await emptyView.refresh()

// Offline after a good poll, with one repo GitHub wouldn't let us read.
let offlineAPI = PartialAPI(base: StaticGitHubAPI(), failedRepos: ["acme/infra"])
let offline = lanesStore(offlineAPI)
await offline.refresh()
await offlineAPI.base.set(error: .offline)
await offline.refresh()

// Rate limited before the first poll ever finished.
let limitedAPI = StaticGitHubAPI()
await limitedAPI.set(error: .rateLimited(resetAt: Date().addingTimeInterval(1800)))
let rateLimited = lanesStore(limitedAPI)
await rateLimited.refresh()

// The first fetch hasn't come back yet.
let loading = lanesStore(StaticGitHubAPI())

// Every view at once.
let allViews = lanesStore(StaticGitHubAPI())
await allViews.refresh()
allViews.selectedViewID = PRStore.allViewsID

// Too many views for tabs in a narrow window: the picker becomes one menu.
let manyViews = PRStore(dependencies: .inMemory(
    api: StaticGitHubAPI(), config: watchingConfig,
    views: SampleData.views + ["Web team", "API on-call", "Release blockers", "Security review"].map { SavedView(name: $0, rule: BuiltInViews.mine.rule) }
))
await manyViews.refresh()
manyViews.selectedViewID = BuiltInViews.mineID

// The main window as a whole: the centered title, the toolbar, the banners and the lanes.
// See WindowRenders.swift for what a windowless render can and can't show of the toolbar.
for dark in [false, true] {
    try render("onboarding-signed-out", OnboardingView(store: signedOut, notifier: notifier), size: CGSize(width: 820, height: 560), dark: dark)
    try render("onboarding-signed-in", OnboardingView(store: signedIn, notifier: notifier), size: CGSize(width: 820, height: 560), dark: dark)
    let lanes: [(String, PRStore, CGSize)] = [
        ("lanes-mine", watching, CGSize(width: 1100, height: 680)),
        ("lanes-just-finished", justFinished, CGSize(width: 1100, height: 680)),
        ("lanes-narrow", watching, CGSize(width: LanesWindowView.minimumWidth, height: 620)),
        ("lanes-narrow-many-views", manyViews, CGSize(width: LanesWindowView.minimumWidth, height: 560)),
        ("lanes-all-views", allViews, CGSize(width: 1440, height: 760)),
        ("lanes-empty-view", emptyView, CGSize(width: 1100, height: 600)),
        ("lanes-offline", offline, CGSize(width: 1100, height: 680)),
        ("lanes-rate-limited", rateLimited, CGSize(width: 1100, height: 600)),
        ("lanes-loading", loading, CGSize(width: 1100, height: 600)),
    ]
    for (name, store, size) in lanes {
        try await renderWindow(name, MainWindowView(store: store, notifier: notifier), size: size, dark: dark)
    }
    // Onboarding in the window: the title bar only, no toolbar.
    try await renderWindow("window-onboarding", MainWindowView(store: signedOut, notifier: notifier), size: CGSize(width: 900, height: 600), dark: dark)
}
// Let `.task` and `onAppear` work settle, then draw the onboarding screens again.
try await Task.sleep(for: .milliseconds(300))
for dark in [false, true] {
    try render("onboarding-signed-in", OnboardingView(store: signedIn, notifier: notifier), size: CGSize(width: 820, height: 560), dark: dark)
}
// The menu bar item, the popover in each state, and each Settings section.
try await MenuBarRenders.renderAll(to: outputDirectory)
// The view editor sheet in each state.
try await renderViewEditor()
print("open in Mine: \(watching.openCount(for: BuiltInViews.mineID))")

/// Wraps an API and reports some repos as unreadable, for the "can't read" banner.
actor PartialAPI: GitHubAPI {
    let base: StaticGitHubAPI
    let failedRepos: [String]

    init(base: StaticGitHubAPI, failedRepos: [String]) {
        self.base = base
        self.failedRepos = failedRepos
    }

    func viewer() async throws -> Viewer { try await base.viewer() }
    func repositories() async throws -> [Repo] { try await base.repositories() }
    func openPullRequests(in repos: [String]) async throws -> OpenPullRequests {
        var result = try await base.openPullRequests(in: repos)
        result.failedRepos = failedRepos
        return result
    }
    func checkDetails(for prs: [PullRequest]) async throws -> [String: CheckSummary] { try await base.checkDetails(for: prs) }
    func latestRateLimit() async -> RateLimit? { await base.latestRateLimit() }
}
