// Renders the menu bar icon in each state, on light and dark menu bars, into docs/:
//
//   menubar-icon.png     each state at 2×, as a Retina menu bar shows it, then magnified 4×
//   menubar-icon-1x.png  each state's pixels at 1× and at 2×, magnified so one point is
//                        4 pixels across, to check the strokes and the rings' holes
//
// Run through scripts/render-menubar-icon.sh, which compiles this with the app's icon code.
import AppKit

let outputDir = URL(fileURLWithPath: CommandLine.arguments[1])
let menuBars: [(background: NSColor, foreground: NSColor)] = [
    (NSColor(white: 0.93, alpha: 1), NSColor.black.withAlphaComponent(0.88)),
    (NSColor(white: 0.16, alpha: 1), NSColor.white.withAlphaComponent(0.88)),
]
let states: [(String, MenuBarIcon.Look, String?)] = [
    ("Calm", .calm, nil),
    ("Your move", .badged, nil),
    ("Event label", .badged, "#1293 ready to merge"),
    ("Offline or signed out", .dimmed, nil),
]

/// The image's pixels at `scale`, tinted as the menu bar tints a template image.
func pixels(_ image: NSImage, scale: CGFloat, color: NSColor) -> CGImage {
    let width = Int((image.size.width * scale).rounded()), height = Int((image.size.height * scale).rounded())
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = image.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(origin: .zero, size: image.size)
    image.draw(in: rect)
    color.set()
    rect.fill(using: .sourceAtop)
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
}

/// Draws a grid: a row per menu bar per scale, a column per state, each pixel `zoom` wide.
func sheet(name: String, title: String, scales: [CGFloat], pointsPerCell zoom: CGFloat) {
    let images = states.map { MenuBarIcon.image($0.1, label: $0.2) }
    let pad: CGFloat = 8 * zoom, captionHeight: CGFloat = 16 * zoom / 2, titleHeight: CGFloat = 36
    let columnWidths = images.map { max($0.size.width * zoom + pad * 2, 160) }
    let rowHeight = MenuBarIcon.height * zoom + pad
    let rows = scales.count * menuBars.count
    let size = NSSize(width: columnWidths.reduce(0, +) + 110,
                      height: CGFloat(rows) * rowHeight + captionHeight + titleHeight)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.interpolationQuality = .none
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.darkGray]
    title.draw(at: NSPoint(x: 12, y: size.height - titleHeight + 10),
               withAttributes: [.font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.black])

    var y = size.height - titleHeight - captionHeight
    var x: CGFloat = 110
    for (state, width) in zip(states, columnWidths) {
        let caption = NSAttributedString(string: state.0, attributes: small)
        caption.draw(at: NSPoint(x: x + (width - caption.size().width) / 2, y: y + 4))
        x += width
    }
    for scale in scales {
        for (bar, menuBar) in menuBars.enumerated() {
            y -= rowHeight
            let label = "\(bar == 0 ? "Light" : "Dark") \(Int(scale))×"
            label.draw(at: NSPoint(x: 12, y: y + rowHeight / 2 - 8), withAttributes: small)
            menuBar.background.setFill()
            NSRect(x: 110, y: y, width: size.width - 110, height: rowHeight - 4).fill()
            x = 110
            for (image, width) in zip(images, columnWidths) {
                let drawn = CGRect(x: x + pad, y: y + (rowHeight - 4 - image.size.height * zoom) / 2,
                                   width: image.size.width * zoom, height: image.size.height * zoom)
                context.draw(pixels(image, scale: scale, color: menuBar.foreground), in: drawn)
                x += width
            }
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    let url = outputDir.appendingPathComponent(name)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("Wrote \(url.path)")
}

MainActor.assumeIsolated {
    sheet(name: "menubar-icon.png", title: "Menu bar icon at 2×, magnified 4×", scales: [2], pointsPerCell: 8)
    sheet(name: "menubar-icon-1x.png", title: "Menu bar icon pixels at 1× and 2×, magnified to 4 pixels a point",
          scales: [1, 2], pointsPerCell: 4)
}
