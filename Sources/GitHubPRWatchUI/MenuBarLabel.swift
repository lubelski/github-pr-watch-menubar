import AppKit
import SwiftUI

/// The menu bar item: a pull-request glyph, with a numbered badge when something is your move.
/// Drawn as a template image so the menu bar tints it; the badge changes the shape, not
/// only the color.
public struct MenuBarLabel: View {
    let count: Int

    public init(count: Int) {
        self.count = count
    }

    public var body: some View {
        Image(nsImage: Self.image(count: count))
            .accessibilityLabel(count > 0 ? "GitHub PR Watch, \(count) need you" : "GitHub PR Watch")
    }

    public static func image(count: Int) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let glyph = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage()
        guard count > 0 else {
            glyph.isTemplate = true
            return glyph
        }

        let text = count > 99 ? "99+" : "\(count)"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let badge = NSSize(width: max(12, textSize.width + 6), height: 12)
        let size = NSSize(width: glyph.size.width + badge.width - 3, height: max(glyph.size.height, 16))

        let image = NSImage(size: size, flipped: false) { _ in
            glyph.draw(in: NSRect(x: 0, y: (size.height - glyph.size.height) / 2, width: glyph.size.width, height: glyph.size.height))
            let badgeRect = NSRect(x: size.width - badge.width, y: size.height - badge.height, width: badge.width, height: badge.height)
            // Clear a ring around the badge so it reads apart from the glyph.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: badgeRect.insetBy(dx: -1.5, dy: -1.5), xRadius: 7.5, yRadius: 7.5).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(roundedRect: badgeRect, xRadius: 6, yRadius: 6).fill()
            // Knock the number out of the badge.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            (text as NSString).draw(
                at: NSPoint(x: badgeRect.midX - textSize.width / 2, y: badgeRect.midY - textSize.height / 2),
                withAttributes: [.font: font, .foregroundColor: NSColor.black]
            )
            return true
        }
        image.isTemplate = true
        return image
    }
}
