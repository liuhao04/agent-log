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

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Could not create bitmap for \(pixels)x\(pixels)")
    }
    bitmap.size = NSSize(width: pixels, height: pixels)

    let context = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }

    let size = CGFloat(pixels)
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    rect.fill()

    func rounded(_ frame: NSRect, _ radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
    }

    let outerFrame = rect.insetBy(dx: size * 0.055, dy: size * 0.055)
    let outer = rounded(outerFrame, size * 0.215)
    NSGradient(
        colors: [
            NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.13, alpha: 1),
            NSColor(calibratedRed: 0.08, green: 0.20, blue: 0.24, alpha: 1),
            NSColor(calibratedRed: 0.03, green: 0.07, blue: 0.10, alpha: 1),
        ]
    )?.draw(in: outer, angle: -38)

    NSColor(calibratedWhite: 1, alpha: 0.16).setStroke()
    outer.lineWidth = max(1, size * 0.009)
    outer.stroke()

    let panelFrame = NSRect(x: size * 0.19, y: size * 0.19, width: size * 0.56, height: size * 0.64)
    let panel = rounded(panelFrame, size * 0.075)
    NSColor(calibratedRed: 0.94, green: 0.97, blue: 0.96, alpha: 1).setFill()
    panel.fill()

    NSColor(calibratedRed: 0.70, green: 0.79, blue: 0.78, alpha: 1).setStroke()
    panel.lineWidth = max(1, size * 0.006)
    panel.stroke()

    let fold = NSBezierPath()
    fold.move(to: NSPoint(x: panelFrame.maxX - size * 0.16, y: panelFrame.maxY))
    fold.line(to: NSPoint(x: panelFrame.maxX, y: panelFrame.maxY - size * 0.16))
    fold.line(to: NSPoint(x: panelFrame.maxX - size * 0.16, y: panelFrame.maxY - size * 0.16))
    fold.close()
    NSColor(calibratedRed: 0.75, green: 0.87, blue: 0.86, alpha: 1).setFill()
    fold.fill()

    let cyan = NSColor(calibratedRed: 0.05, green: 0.56, blue: 0.62, alpha: 1)
    cyan.setFill()
    rounded(
        NSRect(x: size * 0.27, y: size * 0.61, width: size * 0.32, height: size * 0.074),
        size * 0.028
    ).fill()

    let ink = NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.23, alpha: 1)
    ink.setFill()
    for index in 0..<4 {
        let y = size * (0.51 - CGFloat(index) * 0.085)
        let width = size * [0.38, 0.30, 0.36, 0.24][index]
        rounded(
            NSRect(x: size * 0.28, y: y, width: width, height: size * 0.032),
            size * 0.014
        ).fill()
    }

    let hitColor = NSColor(calibratedRed: 0.96, green: 0.67, blue: 0.23, alpha: 1)
    hitColor.setFill()
    rounded(
        NSRect(x: size * 0.50, y: size * 0.425, width: size * 0.15, height: size * 0.038),
        size * 0.017
    ).fill()

    let lensFrame = NSRect(x: size * 0.52, y: size * 0.27, width: size * 0.24, height: size * 0.24)
    let lens = NSBezierPath(ovalIn: lensFrame)
    NSColor(calibratedRed: 0.03, green: 0.09, blue: 0.10, alpha: 0.14).setFill()
    NSBezierPath(ovalIn: lensFrame.offsetBy(dx: size * 0.018, dy: -size * 0.018)).fill()

    cyan.setStroke()
    lens.lineWidth = max(2, size * 0.035)
    lens.stroke()

    let handle = NSBezierPath()
    handle.move(to: NSPoint(x: size * 0.70, y: size * 0.31))
    handle.line(to: NSPoint(x: size * 0.82, y: size * 0.19))
    handle.lineCapStyle = .round
    handle.lineWidth = max(2, size * 0.044)
    cyan.setStroke()
    handle.stroke()

    NSColor(calibratedWhite: 1, alpha: 0.85).setStroke()
    let innerLens = NSBezierPath(ovalIn: lensFrame.insetBy(dx: size * 0.046, dy: size * 0.046))
    innerLens.lineWidth = max(1, size * 0.01)
    innerLens.stroke()

    return bitmap
}

for output in outputs {
    let bitmap = drawIcon(pixels: output.pixels)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not render \(output.name)")
    }
    try png.write(to: iconDir.appendingPathComponent(output.name))
}
