// Draws the TeXSnap app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift <output.icns>
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Rounded-square body on Apple's 1024 grid (824 pt shape, 185 pt corners), with a soft shadow.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 22 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSColor(calibratedRed: 0.27, green: 0.23, blue: 0.85, alpha: 1).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.30, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.13, green: 0.47, blue: 0.96, alpha: 1),
    ])!
    gradient.draw(in: path, angle: -60)

    // Snip corner marks.
    let white = NSColor.white
    white.withAlphaComponent(0.9).setStroke()
    let inset: CGFloat = 215 * s
    let arm: CGFloat = 105 * s
    let corners = [
        (NSPoint(x: inset, y: 1024 * s - inset), CGFloat(1), CGFloat(-1)),
        (NSPoint(x: 1024 * s - inset, y: 1024 * s - inset), CGFloat(-1), CGFloat(-1)),
        (NSPoint(x: inset, y: inset), CGFloat(1), CGFloat(1)),
        (NSPoint(x: 1024 * s - inset, y: inset), CGFloat(-1), CGFloat(1)),
    ]
    for (point, dx, dy) in corners {
        let mark = NSBezierPath()
        mark.lineWidth = 34 * s
        mark.lineCapStyle = .round
        mark.lineJoinStyle = .round
        mark.move(to: NSPoint(x: point.x, y: point.y + dy * arm))
        mark.line(to: point)
        mark.line(to: NSPoint(x: point.x + dx * arm, y: point.y))
        mark.stroke()
    }

    // The formula glyph.
    let config = NSImage.SymbolConfiguration(pointSize: 380 * s, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [white]))
    if let symbol = NSImage(systemSymbolName: "x.squareroot", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let glyph = symbol.size
        symbol.draw(in: NSRect(x: (1024 * s - glyph.width) / 2, y: (1024 * s - glyph.height) / 2,
                               width: glyph.width, height: glyph.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("TeXSnap-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let rep = drawIcon(size: CGFloat(base * scale))
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(output)")
