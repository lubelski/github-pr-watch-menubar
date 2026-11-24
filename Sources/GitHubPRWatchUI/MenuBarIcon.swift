import AppKit
#if canImport(GitHubPRWatchCore)
import GitHubPRWatchCore
#endif

/// Draws the menu bar item: the app's pull request mark as one template image, so the menu
/// bar tints it for light and dark menu bars. A badge changes the shape, not only the color,
/// and a short label can sit to its right.
///
/// It uses only AppKit and `PullRequestMark`, so `scripts/render-menubar-icon.sh` can
/// compile it on its own. `MenuBarLabel` chooses the look from the app's state.
public enum MenuBarIcon {
    public enum Look: Sendable, CaseIterable {
        /// Watching, nothing changed since you last looked.
        case calm
        /// Something changed since you last looked: a filled badge beside the mark's top right.
        case badged
        /// Offline or signed out: the mark at 40% opacity.
        case dimmed
    }

    /// The height of the image. The mark is 15 points tall inside it.
    public static let height: CGFloat = 18
    static let style = PullRequestMark.Style.menuBar
    static let badgeDiameter: CGFloat = 6
    /// The gap between the mark's right edge and the badge. The badge sits beside the mark,
    /// not over it, because the mark's top right is the right track's bend, and cutting into
    /// it breaks the shape.
    static let badgeGap: CGFloat = 1.5
    static let labelSpacing: CGFloat = 5

    public static func image(_ look: Look, label: String? = nil) -> NSImage {
        let mark = PullRequestMark.path(style)
        let ink = mark.boundingBoxOfPath
        // Put the mark's left edge at x = 0 and center it up and down, then nudge both to
        // the quarter point `menuBarOffset` asks for, so its edges land on 2× pixels.
        let origin = CGPoint(
            x: snap(-ink.minX, to: PullRequestMark.Style.menuBarOffset.x),
            y: snap((height - ink.height) / 2 - ink.minY, to: PullRequestMark.Style.menuBarOffset.y)
        )
        let markWidth = ceil(origin.x + ink.maxX)
        let glyphWidth = markWidth + (look == .badged ? badgeGap + badgeDiameter : 0)

        let font = NSFont.menuBarFont(ofSize: 0)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let text = label.map { NSAttributedString(string: $0, attributes: attributes) }
        let textSize = text?.size() ?? .zero
        let spacing = text == nil ? 0 : labelSpacing
        let size = NSSize(width: ceil(glyphWidth + spacing + textSize.width), height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            if look == .dimmed { context.setAlpha(0.4) }
            context.translateBy(x: origin.x, y: origin.y)
            context.addPath(mark)
            context.setFillColor(.black)
            context.fillPath()
            context.restoreGState()

            if look == .badged {
                // Level with the top of the mark, just past its right edge.
                let badge = CGRect(
                    x: markWidth + badgeGap, y: (origin.y + ink.maxY).rounded() - badgeDiameter,
                    width: badgeDiameter, height: badgeDiameter
                )
                context.setFillColor(.black)
                context.fillEllipse(in: badge)
            }

            if let text {
                text.draw(at: NSPoint(x: glyphWidth + spacing, y: ((size.height - textSize.height) / 2).rounded()))
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The nearest value to `value` that is `offset` past a whole half point.
    static func snap(_ value: CGFloat, to offset: CGFloat) -> CGFloat {
        ((value - offset) * 2).rounded(.up) / 2 + offset
    }
}
