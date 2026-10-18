// Renders the LogiLight app icon into an .iconset directory.

import Cocoa

let size = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("could not allocate the icon bitmap")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let canvas = NSRect(x: 0, y: 0, width: size, height: size)
let inset: CGFloat = 64
let background = canvas.insetBy(dx: inset, dy: inset)
let radius = background.width * 0.22
let shape = NSBezierPath(roundedRect: background, xRadius: radius, yRadius: radius)

let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 1),
    NSColor(srgbRed: 0.04, green: 0.05, blue: 0.07, alpha: 1),
])!
gradient.draw(in: shape, angle: -90)

// Warm ring with a gap at the top: the universal power symbol.
let center = NSPoint(x: canvas.midX, y: canvas.midY - 12)
let ringRadius = background.width * 0.26
let ring = NSBezierPath()
ring.appendArc(withCenter: center, radius: ringRadius, startAngle: 112, endAngle: 68, clockwise: false)
ring.lineWidth = background.width * 0.075
ring.lineCapStyle = .round
NSColor(srgbRed: 1.0, green: 0.72, blue: 0.25, alpha: 1).setStroke()
ring.stroke()

let stem = NSBezierPath()
stem.move(to: NSPoint(x: center.x, y: center.y + ringRadius * 0.05))
stem.line(to: NSPoint(x: center.x, y: center.y + ringRadius * 1.18))
stem.lineWidth = background.width * 0.075
stem.lineCapStyle = .round
NSColor(srgbRed: 1.0, green: 0.82, blue: 0.45, alpha: 1).setStroke()
stem.stroke()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode the icon")
}

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("icon_1024.png"))
print("wrote \(output)/icon_1024.png")
