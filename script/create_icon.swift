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
    let wave = NSBezierPath()
    wave.lineWidth = 25; wave.lineCapStyle = .round; wave.lineJoinStyle = .round
    wave.move(to: NSPoint(x: 98, y: 245))
    for (x,y) in [(160,245),(191,328),(240,160),(282,297),(315,245),(402,245)] { wave.line(to: NSPoint(x:x, y:y)) }
    wave.stroke()
    NSColor(calibratedRed: 1, green: 0.43, blue: 0.27, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 354, y: 355, width: 48, height: 48)).fill()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
}
