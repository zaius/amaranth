#!/usr/bin/env swift
// Renders the app icon: a white lightbulb glyph on an amaranth-red gradient,
// rounded to the macOS app-icon superellipse-ish corner. Produces a 1024px PNG.
// The justfile / `iconutil` turns the PNG into Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift out.png
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let px = 1024

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let size = CGFloat(px)
let rect = NSRect(x: 0, y: 0, width: size, height: size)

// Rounded-rect background clip + amaranth gradient.
let radius = size * 0.2237
NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
NSGradient(colors: [
    NSColor(srgbRed: 0.93, green: 0.24, blue: 0.40, alpha: 1),  // amaranth
    NSColor(srgbRed: 0.52, green: 0.06, blue: 0.27, alpha: 1),  // deep crimson
])!.draw(in: rect, angle: -90)

// White lightbulb glyph, centered.
let conf = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
let names = ["lightbulb.led.fill", "lightbulb.fill", "lightbulb.led", "lightbulb"]
if let symbol = names.lazy
    .compactMap({ NSImage(systemSymbolName: $0, accessibilityDescription: nil) })
    .first?
    .withSymbolConfiguration(conf) {
    let s = symbol.size
    symbol.draw(
        in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height),
        from: .zero, operation: .sourceOver, fraction: 1
    )
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to encode PNG\n".utf8)); exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
