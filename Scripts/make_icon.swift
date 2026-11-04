// Draws the MacTools app icon (1024×1024 PNG). Used by build.sh.
// Usage: make_icon <output.png>
import AppKit

let size = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else {
    exit(1)
}
rep.size = NSSize(width: size, height: size)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

let canvas = NSRect(x: 0, y: 0, width: size, height: size)
let body = canvas.insetBy(dx: 100, dy: 100)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

// Soft drop shadow
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

// Gradient background
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.20, green: 0.50, blue: 1.00, alpha: 1),
    NSColor(srgbRed: 0.56, green: 0.27, blue: 0.96, alpha: 1)
])
gradient?.draw(in: shape, angle: -60)

// Subtle top highlight
let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])
highlight?.draw(in: shape, angle: -90)

// White tool symbol
let config = NSImage.SymbolConfiguration(pointSize: 400, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white]))
if let symbol = NSImage(systemSymbolName: "wrench.and.screwdriver.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = symbol.size
    let target = NSRect(x: canvas.midX - s.width / 2, y: canvas.midY - s.height / 2, width: s.width, height: s.height)
    symbol.draw(in: target)
}

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
do {
    try data.write(to: URL(fileURLWithPath: output))
} catch {
    exit(1)
}
