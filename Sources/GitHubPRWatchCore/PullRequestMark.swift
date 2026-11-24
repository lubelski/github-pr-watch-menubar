import CoreGraphics

/// The app's mark: a pull request drawn as two tracks. The left track is a straight line
/// between two rings. The right track rises from a ring, bends left, and ends in an arrowhead
/// pointing back at the left track. It is our own drawing of the idea of the Octicons
/// `git-pull-request` icon (MIT), with the same proportions.
///
/// The app icon, the menu bar icon, and the onboarding header all draw it from here.
/// Geometry is in design units with y pointing up. The ink sits in a box 12 units wide,
/// with the rings 8 units apart across and 10 apart up and down, as in Octicons.
public enum PullRequestMark {
    public struct Style: Sendable, Equatable {
        /// The radius of a ring, to the middle of its stroke.
        public var ringRadius: CGFloat
        /// The width of a ring's stroke.
        public var ringStroke: CGFloat
        /// The width of the two tracks and the arm.
        public var trackStroke: CGFloat
        /// The radius of the right track's bend, to the middle of its stroke.
        public var bendRadius: CGFloat
        /// How far the arrowhead reaches left from its base, and half its height.
        public var arrowLength: CGFloat
        public var arrowHalfHeight: CGFloat
        /// The gap between the arrowhead's tip and the left track's top ring.
        public var arrowGap: CGFloat
        /// The rounding at the arrowhead's corners.
        public var arrowCorner: CGFloat

        public init(
            ringRadius: CGFloat, ringStroke: CGFloat, trackStroke: CGFloat, bendRadius: CGFloat,
            arrowLength: CGFloat, arrowHalfHeight: CGFloat, arrowGap: CGFloat, arrowCorner: CGFloat
        ) {
            self.ringRadius = ringRadius
            self.ringStroke = ringStroke
            self.trackStroke = trackStroke
            self.bendRadius = bendRadius
            self.arrowLength = arrowLength
            self.arrowHalfHeight = arrowHalfHeight
            self.arrowGap = arrowGap
            self.arrowCorner = arrowCorner
        }

        /// The app icon and the onboarding header: Octicons' proportions, with tracks twice
        /// as wide as the rings' stroke, so the mark holds up at 16 points in Finder.
        public static let large = Style(
            ringRadius: 1.5, ringStroke: 1, trackStroke: 2, bendRadius: 2,
            arrowLength: 3, arrowHalfHeight: 3, arrowGap: 0.6, arrowCorner: 0.2
        )

        /// The menu bar, where one unit is one point. One stroke width for rings and tracks,
        /// thinner than `large`'s tracks so the rings' holes stay open at 15 points tall.
        /// Drawn a quarter point off the grid (`menuBarOffset`), every straight edge and the
        /// rings' edges fall on whole pixels at 2×.
        public static let menuBar = Style(
            ringRadius: 1.5, ringStroke: 1.5, trackStroke: 1.5, bendRadius: 2,
            arrowLength: 2.5, arrowHalfHeight: 2.75, arrowGap: 0.5, arrowCorner: 0.1
        )

        /// Where to put the design origin, in points, so `menuBar`'s edges land on 2× pixels.
        public static let menuBarOffset = CGPoint(x: 0.25, y: 0.25)

        var outerRadius: CGFloat { ringRadius + ringStroke / 2 }
        var innerRadius: CGFloat { ringRadius - ringStroke / 2 }
    }

    /// The rings' centers, in design units. The bottom rings sit on the line y = 3, the top
    /// ring and the arm on y = 13, the left track on x = 2 and the right on x = 10.
    static let leftX: CGFloat = 2, rightX: CGFloat = 10, bottomY: CGFloat = 3, topY: CGFloat = 13

    /// The left track: two rings and the line between them.
    public static func leftTrack(_ style: Style) -> CGPath {
        let top = ring(CGPoint(x: leftX, y: topY), style)
        let bottom = ring(CGPoint(x: leftX, y: bottomY), style)
        let line = CGMutablePath()
        line.move(to: CGPoint(x: leftX, y: bottomY + style.innerRadius))
        line.addLine(to: CGPoint(x: leftX, y: topY - style.innerRadius))
        let stem = line.copy(strokingWithWidth: style.trackStroke, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
        return top.union(bottom).union(stem)
    }

    /// The right track: a ring at the bottom, a line up that bends left, and the arrowhead.
    public static func rightTrack(_ style: Style) -> CGPath {
        let ring = ring(CGPoint(x: rightX, y: bottomY), style)
        let tipX = leftX + style.outerRadius + style.arrowGap
        let baseX = tipX + style.arrowLength
        let bendCenter = CGPoint(x: rightX - style.bendRadius, y: topY - style.bendRadius)

        let line = CGMutablePath()
        line.move(to: CGPoint(x: rightX, y: bottomY + style.innerRadius))
        line.addLine(to: CGPoint(x: rightX, y: bendCenter.y))
        line.addArc(center: bendCenter, radius: style.bendRadius, startAngle: 0, endAngle: .pi / 2, clockwise: false)
        // Run the arm a little into the arrowhead so the two join without a seam.
        line.addLine(to: CGPoint(x: baseX - style.arrowCorner * 2, y: topY))
        let arm = line.copy(strokingWithWidth: style.trackStroke, lineCap: .butt, lineJoin: .round, miterLimit: 10)

        // The arrowhead, drawn a corner's width smaller and then grown by stroking it with
        // round joins, so its points are softened but its size is as asked.
        let c = style.arrowCorner
        let triangle = CGMutablePath()
        triangle.move(to: CGPoint(x: tipX + c * 2, y: topY))
        triangle.addLine(to: CGPoint(x: baseX - c, y: topY + style.arrowHalfHeight - c * 1.5))
        triangle.addLine(to: CGPoint(x: baseX - c, y: topY - style.arrowHalfHeight + c * 1.5))
        triangle.closeSubpath()
        let head = c > 0
            ? triangle.union(triangle.copy(strokingWithWidth: c * 2, lineCap: .round, lineJoin: .round, miterLimit: 10))
            : triangle
        return ring.union(arm).union(head)
    }

    /// The whole mark as one outline, in design units.
    public static func path(_ style: Style) -> CGPath {
        leftTrack(style).union(rightTrack(style))
    }

    /// `path` scaled to fit and centered in `rect`. With `flipped`, y points down, for SwiftUI.
    public static func path(_ style: Style, fittedIn rect: CGRect, flipped: Bool = false) -> CGPath {
        let mark = path(style)
        var transform = fitting(mark.boundingBoxOfPath, in: rect, flipped: flipped)
        return mark.copy(using: &transform) ?? mark
    }

    /// The transform that scales a box of design units to fit, centered, in `rect`.
    public static func fitting(_ box: CGRect, in rect: CGRect, flipped: Bool = false) -> CGAffineTransform {
        let scale = min(rect.width / box.width, rect.height / box.height)
        let x = rect.midX - box.midX * scale
        if flipped {
            return CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: x, ty: rect.midY + box.midY * scale)
        }
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: x, ty: rect.midY - box.midY * scale)
    }

    static func ring(_ center: CGPoint, _ style: Style) -> CGPath {
        let circle = CGPath(
            ellipseIn: CGRect(x: center.x - style.ringRadius, y: center.y - style.ringRadius,
                              width: style.ringRadius * 2, height: style.ringRadius * 2),
            transform: nil
        )
        return circle.copy(strokingWithWidth: style.ringStroke, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
    }
}
