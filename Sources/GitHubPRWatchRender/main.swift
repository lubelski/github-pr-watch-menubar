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

for dark in [false, true] {
    try render("onboarding-signed-out", OnboardingView(store: signedOut, notifier: notifier), size: CGSize(width: 820, height: 560), dark: dark)
    try render("onboarding-signed-in", OnboardingView(store: signedIn, notifier: notifier), size: CGSize(width: 820, height: 560), dark: dark)
    try render("lanes-mine", LanesWindowView(store: watching), size: CGSize(width: 1100, height: 620), dark: dark)
    try render("popover", MenuBarPopoverView(store: watching), dark: dark)
    try render("settings", SettingsView(store: watching, notifier: notifier), size: CGSize(width: 520, height: 460), dark: dark)
}
// Let `.task` and `onAppear` work settle, then draw the onboarding screens again.
try await Task.sleep(for: .milliseconds(300))
for dark in [false, true] {
    try render("onboarding-signed-in", OnboardingView(store: signedIn, notifier: notifier), size: CGSize(width: 820, height: 560), dark: dark)
}
try writeImage(MenuBarLabel.image(count: 0), name: "menubar-idle")
try writeImage(MenuBarLabel.image(count: 3), name: "menubar-badge")
print("your move: \(watching.yourMoveCount)")
