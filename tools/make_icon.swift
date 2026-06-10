import AppKit

// Renders the anf app icon to a 1024×1024 PNG: a rounded-squircle tile with a
// blue→indigo gradient and a white folder glyph. Run: swift tools/make_icon.swift <out.png>

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Platform-style margin so the tile doesn't bleed to the canvas edge.
let margin = size * 0.085
let tile = CGRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
let radius = tile.width * 0.2237
let tilePath = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

// Soft drop shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012),
              blur: size * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor.black.setFill()
tilePath.fill()
ctx.restoreGState()

// Gradient fill (clipped to the squircle).
ctx.saveGState()
tilePath.addClip()
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.32, green: 0.55, blue: 1.00, alpha: 1),   // bright blue
    NSColor(srgbRed: 0.36, green: 0.36, blue: 0.92, alpha: 1),   // indigo
    NSColor(srgbRed: 0.46, green: 0.28, blue: 0.85, alpha: 1)    // violet
])!
gradient.draw(in: tile, angle: -90)

// Subtle top highlight.
let highlight = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0.0)
])!
highlight.draw(in: CGRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
ctx.restoreGState()

// White folder glyph, centred.
let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .semibold)
if let symbol = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    NSColor.white.set()
    let r = NSRect(origin: .zero, size: symbol.size)
    symbol.draw(in: r)
    r.fill(using: .sourceAtop)
    tinted.unlockFocus()

    let gw = symbol.size.width, gh = symbol.size.height
    let drawRect = CGRect(x: (size - gw) / 2, y: (size - gh) / 2 - size * 0.01, width: gw, height: gh)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.008),
                  blur: size * 0.02, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    tinted.draw(in: drawRect)
    ctx.restoreGState()
}

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("png encode failed\n".data(using: .utf8)!); exit(1)
}
try! data.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
