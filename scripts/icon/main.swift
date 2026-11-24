// Writes an Icon Composer file from AppIconDrawing: icon.json and one image per layer.
// Also lays out pictures of the compiled icon on one labeled sheet, for docs/.
// Run through scripts/render-icon.sh, which compiles this with the drawing.
//
//   render-icon <path/to/AppIcon.icon> [design number]
//   render-icon --sheet <out.png> <title> (<image.png> <label> <light|dark>)...
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    exit(2)
}

/// Draws each image at its own size, side by side, with its label under it, on a light or
/// dark backdrop as the image's appearance needs.
func sheet(output: URL, title: String, cells: [(image: NSImage, label: String, dark: Bool)]) throws {
    let pad: CGFloat = 24, labelHeight: CGFloat = 34, titleHeight: CGFloat = 40
    let cellHeight = (cells.map(\.image.size.height).max() ?? 0) + pad * 2
    let widths = cells.map { max($0.image.size.width + pad * 2, 150) }
    let size = NSSize(width: widths.reduce(0, +), height: cellHeight + labelHeight + titleHeight)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fail("couldn't make the sheet") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(white: 0.97, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.black]
    title.draw(at: NSPoint(x: pad, y: size.height - titleHeight + 10), withAttributes: titleAttributes)
    var x: CGFloat = 0
    for (cell, width) in zip(cells, widths) {
        let backdrop = NSRect(x: x, y: labelHeight, width: width, height: cellHeight)
        (cell.dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.90, alpha: 1)).setFill()
        backdrop.insetBy(dx: 4, dy: 0).fill()
        let imageSize = cell.image.size
        cell.image.draw(in: NSRect(x: backdrop.midX - imageSize.width / 2, y: backdrop.midY - imageSize.height / 2,
                                   width: imageSize.width, height: imageSize.height))
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.darkGray]
        let label = NSAttributedString(string: cell.label, attributes: attributes)
        label.draw(at: NSPoint(x: x + (width - label.size().width) / 2, y: 10))
        x += width
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else { fail("couldn't encode the sheet") }
    try data.write(to: output)
}

let arguments = CommandLine.arguments
if arguments.count >= 2, arguments[1] == "--sheet" {
    guard arguments.count >= 4, (arguments.count - 4) % 3 == 0 else {
        fail("usage: render-icon --sheet <out.png> <title> (<image.png> <label> <light|dark>)...")
    }
    var cells: [(image: NSImage, label: String, dark: Bool)] = []
    for i in stride(from: 4, to: arguments.count, by: 3) {
        guard let rep = NSImageRep(contentsOfFile: arguments[i]) else { fail("couldn't read \(arguments[i])") }
        // Show each picture at its pixel size, so a 2× export is drawn at 2× its points.
        let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        image.addRepresentation(rep)
        cells.append((image, arguments[i + 1], arguments[i + 2] == "dark"))
    }
    try sheet(output: URL(fileURLWithPath: arguments[2]), title: arguments[3], cells: cells)
    print("Drew \(arguments[2])")
    exit(0)
}

guard arguments.count >= 2 else { fail("usage: render-icon <AppIcon.icon> [design number]") }
var design = AppIconDrawing.shipped
if arguments.count >= 3 {
    guard let number = Int(arguments[2]), let chosen = AppIconDrawing.Design(rawValue: number) else {
        let numbers = AppIconDrawing.Design.allCases.map { "\($0.rawValue) \($0.title)" }.joined(separator: ", ")
        fail("error: the design is one of \(numbers)")
    }
    design = chosen
}

let icon = URL(fileURLWithPath: arguments[1])
let assets = icon.appendingPathComponent("Assets")
let files = FileManager.default
// Start the assets over, so no image from another design is left behind.
try? files.removeItem(at: assets)
try files.createDirectory(at: assets, withIntermediateDirectories: true)

for layer in design.layers {
    let output = assets.appendingPathComponent("\(layer.name).png")
    guard let image = AppIconDrawing.image(of: layer),
          let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("couldn't draw \(layer.name)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("couldn't write \(output.path)") }
}
try AppIconDrawing.iconJSON(for: design).write(
    to: icon.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
print("Drew design \(design.rawValue), \(design.title), into \(icon.path)")
