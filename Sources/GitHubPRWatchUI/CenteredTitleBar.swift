import AppKit
import SwiftUI

/// Puts the app's static name in the middle of the window's title bar, the same on every
/// window, so each one says which app it belongs to.
///
/// Current macOS draws a window's own title at the leading edge, beside the window buttons,
/// and no toolbar style centers it. So the system title is hidden and a label in the title
/// bar's row says it instead. The window keeps its title for the Window menu, Mission Control
/// and VoiceOver. With the expanded toolbar style the title row sits above the toolbar row,
/// so the label is centered above the toolbar's items, not crowded among them.
private struct CenteredTitleBar: NSViewRepresentable {
    let title: String
    let separator: NSTitlebarSeparatorStyle?

    func makeNSView(context: Context) -> TitleBarView { TitleBarView() }

    func updateNSView(_ view: TitleBarView, context: Context) {
        view.title = title
        view.separator = separator
        view.apply()
    }

    final class TitleBarView: NSView {
        var title = ""
        var separator: NSTitlebarSeparatorStyle?

        /// Marks the label, so a window gets one however often SwiftUI updates.
        private static let labelID = NSUserInterfaceItemIdentifier("CenteredTitleBarLabel")

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let window else { return }
            if window.title != title { window.title = title }
            window.titleVisibility = .hidden
            if let separator { window.titlebarSeparatorStyle = separator }
            guard let close = window.standardWindowButton(.closeButton), let bar = close.superview else { return }
            if let label = bar.subviews.first(where: { $0.identifier == Self.labelID }) as? NSTextField {
                label.stringValue = title
                return
            }
            let label = NSTextField(labelWithString: title)
            label.identifier = Self.labelID
            // The font and color the system uses for a window's title.
            label.font = .titleBarFont(ofSize: NSFont.systemFontSize)
            label.textColor = .windowFrameTextColor
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            // VoiceOver reads the window's own title; the label only draws it.
            label.setAccessibilityElement(false)
            bar.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
                // Level with the window buttons, which sit in the title row in every style.
                label.centerYAnchor.constraint(equalTo: close.centerYAnchor),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: bar.leadingAnchor, constant: 80),
            ])
        }
    }
}

public extension View {
    /// A title bar with `title` centered in it, drawn by the window itself.
    ///
    /// `separator` sets the line under the title bar; nil leaves the system's choice, which
    /// for a window with a toolbar is the scroll edge effect on current macOS.
    func centeredTitleBar(_ title: String = AppInfo.name, separator: NSTitlebarSeparatorStyle? = nil) -> some View {
        navigationTitle(title)
            .background(CenteredTitleBar(title: title, separator: separator))
    }
}
