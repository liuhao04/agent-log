import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconDir = root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")

try FileManager.default.createDirectory(at: iconDir, withIntermediateDirectories: true)

let outputs: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    rect.fill()

    let radius = size * 0.22
    let base = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.06, dy: size * 0.06), xRadius: radius, yRadius: radius)
    NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.16, alpha: 1).setFill()
    base.fill()

    let panel = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.17, dy: size * 0.18), xRadius: size * 0.08, yRadius: size * 0.08)
    NSColor(calibratedRed: 0.95, green: 0.97, blue: 0.98, alpha: 1).setFill()
    panel.fill()

    let accent = NSColor(calibratedRed: 0.18, green: 0.48, blue: 0.92, alpha: 1)
    let query = NSBezierPath(
        roundedRect: NSRect(x: size * 0.25, y: size * 0.58, width: size * 0.50, height: size * 0.12),
        xRadius: size * 0.05,
        yRadius: size * 0.05
    )
    accent.setFill()
    query.fill()

    let lineColor = NSColor(calibratedRed: 0.20, green: 0.24, blue: 0.30, alpha: 1)
    lineColor.setFill()
    for index in 0..<3 {
        let y = size * (0.45 - CGFloat(index) * 0.10)
        let width = size * (index == 2 ? 0.34 : 0.48)
        let line = NSBezierPath(
            roundedRect: NSRect(x: size * 0.26, y: y, width: width, height: size * 0.045),
            xRadius: size * 0.02,
            yRadius: size * 0.02
        )
        line.fill()
    }

    let fold = NSBezierPath()
    fold.move(to: NSPoint(x: size * 0.67, y: size * 0.82))
    fold.line(to: NSPoint(x: size * 0.83, y: size * 0.66))
    fold.line(to: NSPoint(x: size * 0.67, y: size * 0.66))
    fold.close()
    NSColor(calibratedRed: 0.80, green: 0.86, blue: 0.93, alpha: 1).setFill()
    fold.fill()

    return image
}

for output in outputs {
    let image = drawIcon(size: CGFloat(output.pixels))
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else {
        fatalError("Could not render \(output.name)")
    }
    try png.write(to: iconDir.appendingPathComponent(output.name))
}
