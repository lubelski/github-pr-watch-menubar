import CoreGraphics
import Foundation

/// Draws the app icon's artwork: the pull request mark in white on a clear background, one
/// image per layer of the Icon Composer file. `scripts/render-icon.sh` turns them into
/// `Resources/AppIcon.icon`, and the system adds the background, the rounded shape, and the
/// glass, in each appearance (default, dark, clear, and tinted).
///
/// There are three designs, kept from when the icon was chosen. They share the mark and
/// differ in background. `shipped` is the one in the app.
public enum AppIconDrawing {
    /// The side of the square canvas, in pixels. Icon Composer's canvas for a Mac icon.
    public static let canvas: CGFloat = 1024

    /// The design in `Resources/AppIcon.icon`.
    public static let shipped = Design.indigo

    public enum Design: Int, CaseIterable, Sendable {
        /// Indigo, from the placeholder the onboarding header used before there was an icon.
        /// The shipped design. It is close to the purple GitHub gives a merged pull request,
        /// without copying it, and differs from the sibling apps' teal, violet, and graphite.
        /// Green reads as "open" and graphite disappears in a dark Dock.
        case indigo = 1
        /// The green GitHub gives an open pull request.
        case openGreen = 2
        /// Near black, the mark alone.
        case graphite = 3

        public var title: String {
            switch self {
            case .indigo: "Indigo"
            case .openGreen: "Open green"
            case .graphite: "Graphite"
            }
        }

        /// The background gradient, top color first, as sRGB components.
        public var gradient: (top: [CGFloat], bottom: [CGFloat]) {
            switch self {
            case .indigo: ([0.40, 0.38, 0.86], [0.18, 0.14, 0.48])
            case .openGreen: ([0.22, 0.66, 0.38], [0.05, 0.33, 0.19])
            case .graphite: ([0.25, 0.26, 0.29], [0.07, 0.07, 0.09])
            }
        }

        /// The layers, front first, as Icon Composer lists them: the right track with its
        /// arrow over the left track, so the glass sets the arrow a little forward.
        public var layers: [Layer] {
            [Layer(name: "arrow", path: PullRequestMark.rightTrack(.large)),
             Layer(name: "branch", path: PullRequestMark.leftTrack(.large))]
        }
    }

    /// One layer of the icon: a name for its image, and its shape in the mark's design units.
    public struct Layer: @unchecked Sendable {
        public let name: String
        public let path: CGPath
    }

    /// Where the mark sits on the canvas: 620 pixels tall, centered, inside the area the
    /// system's rounded shape keeps clear.
    static let markBox = CGRect(x: 202, y: 202, width: 620, height: 620)

    /// Draws one layer in white on a clear canvas.
    public static func image(of layer: Layer) -> CGImage? {
        let size = Int(canvas)
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Fit the whole mark, not the layer, so the layers line up with each other.
        context.concatenate(PullRequestMark.fitting(PullRequestMark.path(.large).boundingBoxOfPath, in: markBox))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.addPath(layer.path)
        context.fillPath()
        return context.makeImage()
    }

    /// The Icon Composer file's `icon.json` for a design, naming each layer's image as
    /// `<name>.png`.
    public static func iconJSON(for design: Design) -> String {
        func color(_ c: [CGFloat]) -> String {
            "srgb:" + (c + [1]).map { String(format: "%.5f", Double($0)) }.joined(separator: ",")
        }
        let layers = design.layers.map {
            """
                    {
                      "image-name" : "\($0.name).png",
                      "name" : "\($0.name)"
                    }
            """
        }.joined(separator: ",\n")
        return """
        {
          "fill" : {
            "linear-gradient" : [
              "\(color(design.gradient.top))",
              "\(color(design.gradient.bottom))"
            ]
          },
          "groups" : [
            {
              "layers" : [
        \(layers)
              ],
              "shadow" : {
                "kind" : "neutral",
                "opacity" : 0.5
              },
              "translucency" : {
                "enabled" : false,
                "value" : 0.5
              }
            }
          ],
          "supported-platforms" : {
            "squares" : [
              "macOS"
            ]
          }
        }

        """
    }
}
