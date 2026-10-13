// Renders Support/Icon.svg into the menu bar template images and an app .iconset.
// Usage: swift Support/make-icons.swift <glyph.svg> <output dir>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let glyph = NSImage(contentsOfFile: arguments[1]) else {
    FileHandle.standardError.write(Data("usage: swift make-icons.swift <glyph.svg> <output dir>\n".utf8))
    exit(1)
}
let output = URL(fileURLWithPath: arguments[2])
let iconset = output.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// Draws into a `pixels`-square bitmap whose coordinate space is `canvas` points wide.
func png(pixels: Int, canvas: CGFloat, draw: () -> Void) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: canvas, height: canvas)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// Menu bar: the bare glyph as an 18pt template image.
for (name, pixels) in [("MenuBarIcon.png", 18), ("MenuBarIcon@2x.png", 36)] {
    let data = png(pixels: pixels, canvas: 18) {
        glyph.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
    }
    try data.write(to: output.appendingPathComponent(name))
}

// App icon: the glyph on a light tile following Apple's macOS grid (824pt tile on a 1024pt canvas).
func appIcon(pixels: Int) -> Data {
    png(pixels: pixels, canvas: 1024) {
        let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.shadowBlurRadius = 20
        shadow.set()
        NSColor.white.setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: .white, ending: NSColor(white: 0.9, alpha: 1))!.draw(in: tile, angle: -90)
        glyph.draw(in: NSRect(x: 192, y: 192, width: 640, height: 640))
    }
}

for points in [16, 32, 128, 256, 512] {
    try appIcon(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try appIcon(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
