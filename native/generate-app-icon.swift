import AppKit
import Foundation

private let arguments = CommandLine.arguments

guard arguments.count == 3 else {
    fputs("Usage: swift native/generate-app-icon.swift <transparent-mark.png> <app-icon.png>\n", stderr)
    exit(64)
}

let sourceURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])

guard let mark = NSImage(contentsOf: sourceURL) else {
    fputs("Could not decode transparent Arco mark at \(sourceURL.path)\n", stderr)
    exit(65)
}

let pixelSize = 1_254
let canvas = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
let tile = canvas.insetBy(dx: 72, dy: 72)
let markFrame = canvas.insetBy(dx: 120, dy: 120)

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixelSize,
    pixelsHigh: pixelSize,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Could not create the Arco app-icon canvas\n", stderr)
    exit(70)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics

NSColor.clear.setFill()
canvas.fill()

let tilePath = NSBezierPath(roundedRect: tile, xRadius: 246, yRadius: 246)
graphics.cgContext.setShadow(
    offset: CGSize(width: 0, height: -12),
    blur: 22,
    color: NSColor.black.withAlphaComponent(0.18).cgColor
)
NSColor.white.setFill()
tilePath.fill()
graphics.cgContext.setShadow(offset: .zero, blur: 0, color: nil)

mark.draw(in: markFrame, from: .zero, operation: .sourceOver, fraction: 1)

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not encode the Arco app icon as PNG\n", stderr)
    exit(70)
}

do {
    try png.write(to: outputURL, options: .atomic)
} catch {
    fputs("Could not write \(outputURL.path): \(error)\n", stderr)
    exit(74)
}
