import AppKit
import GitHubPRWatchCore
import SwiftUI

/// The menu bar item (Figma row 3B): a pull-request glyph that stays calm until something
/// needs you, then gains a filled badge. Offline or signed out, it dims. Right after an
/// event a short label such as `#1293 ready to merge` sits next to it for a few seconds.
///
/// Everything is drawn into one template image, so the menu bar tints it for light and
/// dark menu bars, and the badge changes the shape, not only the color.
public struct MenuBarLabel: View {
    let indicator: MenuBarIndicator
    let transientLabel: String?

    public init(indicator: MenuBarIndicator, transientLabel: String? = nil) {
        self.indicator = indicator
        self.transientLabel = transientLabel
    }

    public var body: some View {
        Image(nsImage: Self.image(indicator: indicator, label: transientLabel))
            .accessibilityLabel(accessibilityText)
            .help(accessibilityText)
    }

    private var accessibilityText: String {
        [indicator.accessibilityText, transientLabel].compactMap { $0 }.joined(separator: ". ")
    }

    static let glyphPointSize: CGFloat = 14
    static let height: CGFloat = 18

    public static func image(indicator: MenuBarIndicator, label: String? = nil) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: glyphPointSize, weight: .regular)
        let glyph = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage()
        let dimmed: Bool
        let badged: Bool
        switch indicator {
        case .signedOut, .offline: (dimmed, badged) = (true, false)
        case .calm: (dimmed, badged) = (false, false)
        case .needsYou: (dimmed, badged) = (false, true)
        }

        let badgeDiameter: CGFloat = 7
        let badgeOverhang: CGFloat = badged ? badgeDiameter - 1 : 0
        let glyphWidth = glyph.size.width + badgeOverhang
        let font = NSFont.menuBarFont(ofSize: 0)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let text = label.map { NSAttributedString(string: $0, attributes: attributes) }
        let textSize = text?.size() ?? .zero
        let spacing: CGFloat = text == nil ? 0 : 5
        let size = NSSize(width: ceil(glyphWidth + spacing + textSize.width), height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            let glyphRect = NSRect(
                x: 0, y: ((size.height - glyph.size.height) / 2).rounded(),
                width: glyph.size.width, height: glyph.size.height
            )
            glyph.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: dimmed ? 0.4 : 1)

            if badged {
                let badge = NSRect(
                    x: glyphRect.maxX - 1, y: min(glyphRect.maxY - badgeDiameter + 1, height - badgeDiameter - 0.5),
                    width: badgeDiameter, height: badgeDiameter
                )
                // Clear a ring so the badge reads apart from the glyph, then fill it.
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: badge.insetBy(dx: -1.5, dy: -1.5)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.black.setFill()
                NSBezierPath(ovalIn: badge).fill()
            }

            if let text {
                let origin = NSPoint(x: glyphWidth + spacing, y: ((size.height - textSize.height) / 2).rounded())
                text.draw(at: origin)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = indicator.accessibilityText
        return image
    }
}

/// The menu bar item wired to the app: reads the store and the activity, and lets summary
/// banners open the main window.
public struct MenuBarItemLabel: View {
    let services: AppServices
    @Environment(\.openWindow) private var openWindow

    public init(services: AppServices) {
        self.services = services
    }

    public var body: some View {
        let store = services.store
        let indicator = MenuBarIndicator.make(
            isSignedIn: store.viewer != nil, needsOnboarding: store.needsOnboarding,
            connection: store.connection, yourMoveCount: store.yourMoveCount
        )
        MenuBarLabel(indicator: indicator, transientLabel: services.activity.transientLabel)
            .task {
                services.registerWindowOpener {
                    openWindow(id: AppInfo.mainWindowID)
                    NSApp.activate()
                }
            }
    }
}
