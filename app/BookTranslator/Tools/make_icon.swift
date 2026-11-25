// Renders the app icon: a full-bleed blue square with a white translate glyph. macOS 26 applies its own
// squircle mask, so the artwork must fill the whole canvas (no margin, no corners, no shadow of its own).
// Usage: swift Tools/make_icon.swift Sources/Assets.xcassets/AppIcon.appiconset
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let canvas: CGFloat = 1024

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)   // 72 dpi: the asset compiler reads pixels and dpi together
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let scale = CGFloat(pixels) / canvas
    ctx.cgContext.scaleBy(x: scale, y: scale)

    // Full bleed: the artwork covers the canvas edge to edge and macOS cuts the shape.
    let tile = NSRect(x: 0, y: 0, width: canvas, height: canvas)
    let path = NSBezierPath(rect: tile)

    NSGradient(colors: [NSColor(calibratedRed: 0.31, green: 0.58, blue: 0.98, alpha: 1),
                        NSColor(calibratedRed: 0.0, green: 0.38, blue: 0.84, alpha: 1),
                        NSColor(calibratedRed: 0.04, green: 0.27, blue: 0.66, alpha: 1)])!
        .draw(in: path, angle: -60)

    // Soft top highlight.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.20), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: 0, y: 512, width: canvas, height: 512), angle: -90)

    // The translate glyph in white line art: two overlapping squares, "文" and "A", dotted rules.
    let cg = ctx.cgContext
    let white = NSColor.white
    let back = CGRect(x: 287, y: 462, width: 280, height: 280)      // holds 文
    let front = CGRect(x: 457, y: 282, width: 280, height: 280)     // holds A
    let radius: CGFloat = 46
    let stroke: CGFloat = 22

    func rounded(_ r: CGRect) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }
    func dotted(from: CGPoint, to: CGPoint) {
        cg.saveGState()
        cg.setStrokeColor(white.cgColor)
        cg.setLineWidth(13)
        cg.setLineCap(.round)
        cg.setLineDash(phase: 0, lengths: [0.1, 27])
        cg.move(to: from)
        cg.addLine(to: to)
        cg.strokePath()
        cg.restoreGState()
    }
    func label(_ text: String, font: NSFont, center: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: white]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes)
    }

    cg.saveGState()
    cg.translateBy(x: canvas / 2, y: canvas / 2)
    cg.scaleBy(x: 1.14, y: 1.14)
    cg.translateBy(x: -canvas / 2, y: -canvas / 2)
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    cg.beginTransparencyLayer(auxiliaryInfo: nil)

    // Back square, with a gap cut around the front one so the two read as layers.
    cg.saveGState()
    let outside = CGMutablePath()
    outside.addRect(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    outside.addPath(rounded(front.insetBy(dx: -(stroke / 2 + 14), dy: -(stroke / 2 + 14))))
    cg.addPath(outside)
    cg.clip(using: .evenOdd)
    cg.setStrokeColor(white.cgColor)
    cg.setLineWidth(stroke)
    cg.addPath(rounded(back))
    cg.strokePath()
    dotted(from: CGPoint(x: back.minX + 52, y: back.maxY - 56), to: CGPoint(x: back.maxX - 52, y: back.maxY - 56))
    label("\u{6587}", font: NSFont(name: "PingFangSC-Semibold", size: 150) ?? NSFont.systemFont(ofSize: 150, weight: .semibold),
          center: CGPoint(x: back.midX - 22, y: back.midY + 8))
    cg.restoreGState()

    // Front square.
    cg.setStrokeColor(white.cgColor)
    cg.setLineWidth(stroke)
    cg.addPath(rounded(front))
    cg.strokePath()
    dotted(from: CGPoint(x: front.minX + 52, y: front.minY + 56), to: CGPoint(x: front.maxX - 52, y: front.minY + 56))
    label("A", font: NSFont.systemFont(ofSize: 160, weight: .bold), center: CGPoint(x: front.midX + 20, y: front.midY - 6))
    // The diagonal that ties the two together.
    dotted(from: CGPoint(x: front.minX + 4, y: back.minY + 76), to: CGPoint(x: back.maxX - 4, y: front.maxY - 76))

    cg.endTransparencyLayer()
    cg.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let entries: [(name: String, points: Int, scale: Int)] = [
    ("16", 16, 1), ("16@2x", 16, 2), ("32", 32, 1), ("32@2x", 32, 2), ("128", 128, 1), ("128@2x", 128, 2),
    ("256", 256, 1), ("256@2x", 256, 2), ("512", 512, 1), ("512@2x", 512, 2),
]
var images: [[String: String]] = []
for e in entries {
    let file = "icon_\(e.name).png"
    try! render(pixels: e.points * e.scale).write(to: URL(fileURLWithPath: outDir).appendingPathComponent(file))
    images.append(["filename": file, "idiom": "mac", "scale": "\(e.scale)x", "size": "\(e.points)x\(e.points)"])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let data = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("Contents.json"))
print("wrote \(entries.count) icons to \(outDir)")
