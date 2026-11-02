import AppKit

// Draw at each target resolution so the rounded rays stay crisp at small sizes.
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = output.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
}

func drawIcon(pixels: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    // A soft violet tile with a warm, inflated sun.
    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 210, yRadius: 210)
    NSGraphicsContext.saveGraphicsState()
    let tileShadow = NSShadow()
    tileShadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    tileShadow.shadowBlurRadius = 28
    tileShadow.shadowOffset = NSSize(width: 0, height: -14)
    tileShadow.set()
    color(0.28, 0.22, 0.70).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0.24, 0.20, 0.62), color(0.48, 0.40, 0.89), color(0.68, 0.60, 0.99)])!
        .draw(in: tile, angle: 70)
    NSColor.white.withAlphaComponent(0.24).setStroke()
    tile.lineWidth = 3
    tile.stroke()

    for index in 0..<8 {
        NSGraphicsContext.saveGraphicsState()
        cg.translateBy(x: 512, y: 520)
        cg.rotate(by: CGFloat(index) * .pi / 4)
        let ray = NSBezierPath(roundedRect: NSRect(x: -27, y: 245, width: 54, height: 103), xRadius: 27, yRadius: 27)
        let shadow = NSShadow()
        shadow.shadowColor = color(0.19, 0.10, 0.40).withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        shadow.set()
        color(1, 0.76, 0.37).setFill()
        ray.fill()
        NSShadow().set()
        NSGradient(colors: [color(1, 0.65, 0.23), color(1, 0.90, 0.60)])!.draw(in: ray, angle: 90)
        NSGraphicsContext.restoreGraphicsState()
    }

    let sun = NSBezierPath(ovalIn: NSRect(x: 307, y: 315, width: 410, height: 410))
    NSGraphicsContext.saveGraphicsState()
    let sunShadow = NSShadow()
    sunShadow.shadowColor = color(0.22, 0.08, 0.36).withAlphaComponent(0.4)
    sunShadow.shadowBlurRadius = 36
    sunShadow.shadowOffset = NSSize(width: 0, height: -18)
    sunShadow.set()
    color(1, 0.66, 0.2).setFill()
    sun.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(1, 0.55, 0.20), color(1, 0.79, 0.31), color(1, 0.96, 0.70)])!
        .draw(in: sun, angle: 70)
    NSColor.white.withAlphaComponent(0.48).setStroke()
    sun.lineWidth = 4
    sun.stroke()

    // A broad translucent highlight gives the sun a bubble-like finish.
    NSGraphicsContext.saveGraphicsState()
    sun.addClip()
    let shine = NSBezierPath(ovalIn: NSRect(x: 348, y: 536, width: 268, height: 155))
    NSGradient(starting: NSColor.white.withAlphaComponent(0), ending: NSColor.white.withAlphaComponent(0.62))!
        .draw(in: shine, angle: 90)
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let data = try drawIcon(pixels: size * scale)
        try data.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
print("Generated app icon")
