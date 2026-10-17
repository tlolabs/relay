import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for (name, pixels) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(pixels) / 512, y: CGFloat(pixels) / 512)
    let background = NSBezierPath(roundedRect: NSRect(x: 16, y: 16, width: 480, height: 480), xRadius: 108, yRadius: 108)
    NSGradient(starting: NSColor(calibratedRed: 0.05, green: 0.64, blue: 0.67, alpha: 1),
        ending: NSColor(calibratedRed: 0.04, green: 0.28, blue: 0.43, alpha: 1))!.draw(in: background, angle: -70)
    NSColor.white.withAlphaComponent(0.95).setStroke()
    for x: CGFloat in [82, 302] {
        let card = NSBezierPath(roundedRect: NSRect(x: x, y: 156, width: 128, height: 200), xRadius: 24, yRadius: 24)
        card.lineWidth = 16; card.stroke()
    }
    NSColor(calibratedRed: 1, green: 0.61, blue: 0.34, alpha: 1).setFill()
    let play = NSBezierPath(); play.move(to: NSPoint(x: 125, y: 214)); play.line(to: NSPoint(x: 125, y: 298)); play.line(to: NSPoint(x: 178, y: 256)); play.close(); play.fill()
    NSColor.white.setStroke()
    let arrow = NSBezierPath(); arrow.lineWidth = 18; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 225, y: 256)); arrow.line(to: NSPoint(x: 283, y: 256)); arrow.move(to: NSPoint(x: 264, y: 278)); arrow.line(to: NSPoint(x: 286, y: 256)); arrow.line(to: NSPoint(x: 264, y: 234)); arrow.stroke()
    let lines = NSBezierPath(); lines.lineWidth = 12; lines.lineCapStyle = .round
    for y: CGFloat in [226, 256, 286] { lines.move(to: NSPoint(x: 331, y: y)); lines.line(to: NSPoint(x: 401, y: y)) }; lines.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
}
