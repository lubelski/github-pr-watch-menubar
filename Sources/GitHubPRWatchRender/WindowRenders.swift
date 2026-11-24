import AppKit
import GitHubPRWatchCore
import GitHubPRWatchUI
import SwiftUI

/// Draws a view as a whole window: title bar, toolbar and content.
///
/// The view goes in an `NSHostingController` that hands its toolbar and title to the window,
/// as the app's `Window` scene does, inside an `NSWindow` that is never ordered front. Then the
/// window's frame view (the content view's superview, which also holds the title bar and the
/// toolbar) is drawn with `cacheDisplay(in:to:)`.
///
/// What this can't show: Liquid Glass. The glass is composited by the window server from what
/// is behind the window, and a window that is never on screen has nothing behind it. The
/// toolbar's items, their grouping into shapes, the centered title, and the layout are real;
/// the glass material itself is a flat stand-in and has to be judged in the running app.
@MainActor
func renderWindow<V: View>(
    _ name: String, _ view: V, size: CGSize, dark: Bool,
    toolbarStyle: NSWindow.ToolbarStyle = .expanded, to folder: URL = outputDirectory
) async throws {
    let host = NSHostingController(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
    host.sceneBridgingOptions = [.toolbars, .title]
    host.sizingOptions = []
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let window = NSWindow(
        contentRect: CGRect(origin: .zero, size: size),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false
    )
    window.appearance = appearance
    window.contentViewController = host
    window.toolbarStyle = toolbarStyle
    window.setContentSize(size)
    guard let frameView = window.contentView?.superview else { return }
    for _ in 0..<4 {
        window.setContentSize(size)
        frameView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
    }
    showSelectionsInactive(in: frameView)
    guard let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
    frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
    let file = folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
    try bitmap.representation(using: .png, properties: [:])?.write(to: file)
    print("wrote \(file.path)")
}

/// Each Settings section as the whole Settings window, with its sidebar and title bar.
@MainActor
func renderSettings(watching: PRStore, signedOut: PRStore, notifier: RecordingNotifier) async throws {
    let size = SettingsView.idealSize
    for dark in [false, true] {
        for tab in SettingsTab.allCases {
            try await renderWindow(
                "settings-\(tab.rawValue)", SettingsView(store: watching, notifier: notifier, tab: tab),
                size: size, dark: dark, toolbarStyle: .automatic
            )
        }
        try await renderWindow(
            "settings-account-signed-out", SettingsView(store: signedOut, notifier: notifier, tab: .account),
            size: size, dark: dark, toolbarStyle: .automatic
        )
        try await renderWindow(
            "settings-notifications-denied",
            SettingsView(store: watching, notifier: RecordingNotifier(status: .denied), tab: .notifications),
            size: size, dark: dark, toolbarStyle: .automatic
        )
        try await renderWindow(
            "settings-notifications-not-asked",
            SettingsView(store: watching, notifier: RecordingNotifier(status: .notDetermined), tab: .notifications),
            size: size, dark: dark, toolbarStyle: .automatic
        )
    }
}

/// Draws selection highlights as they look in a window that isn't key.
///
/// A sidebar's selected row is an `NSVisualEffectView` that samples what is behind the
/// window. A window that is never on screen has nothing behind it, so the highlight draws
/// solid black. Here each one is swapped for the flat gray highlight a sidebar shows when its
/// window isn't key, and the row is told it isn't emphasized, so its text draws dark.
@MainActor
func showSelectionsInactive(in view: NSView) {
    if let effect = view as? NSVisualEffectView, effect.material == .selection, !effect.isHidden {
        (effect.superview as? NSTableRowView)?.isEmphasized = false
        effect.isHidden = true
        let flat = NSView(frame: effect.frame)
        flat.wantsLayer = true
        flat.layer?.cornerRadius = effect.layer?.cornerRadius ?? 8
        var color = NSColor.clear.cgColor
        effect.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
        }
        flat.layer?.backgroundColor = color
        effect.superview?.addSubview(flat, positioned: .below, relativeTo: effect)
    }
    for sub in view.subviews { showSelectionsInactive(in: sub) }
}
