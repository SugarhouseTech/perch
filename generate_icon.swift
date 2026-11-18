#!/usr/bin/env swift
// Draws the app icon, a white pushpin tilted into a blue tile, and writes
// Resources/AppIcon.icns. Run from the repository root:
//
//     swift generate_icon.swift
//
// The pin is the same shape as the menu bar glyph (MenuBarGlyph.swift), drawn
// on a 24 unit grid with y pointing down. The tile follows Apple's macOS icon
// grid: an 824 pixel rounded square centred on a 1024 pixel canvas.

import AppKit

/// The pushpin's head, collar and skirt, on the 24 unit grid.
func pinBody() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 8.6, y: 3.25))
    p.addLine(to: CGPoint(x: 15.4, y: 3.25))
    p.addArc(center: CGPoint(x: 15.4, y: 4.5), radius: 1.25,
             startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
    p.addLine(to: CGPoint(x: 14.75, y: 5.75))
    p.addLine(to: CGPoint(x: 14.75, y: 10.15))
    p.addLine(to: CGPoint(x: 18.15, y: 14.25))
    p.addLine(to: CGPoint(x: 5.85, y: 14.25))
    p.addLine(to: CGPoint(x: 9.25, y: 10.15))
    p.addLine(to: CGPoint(x: 9.25, y: 5.75))
    p.addLine(to: CGPoint(x: 8.6, y: 5.75))
    p.addArc(center: CGPoint(x: 8.6, y: 4.5), radius: 1.25,
             startAngle: .pi / 2, endAngle: 3 * .pi / 2, clockwise: false)
    p.closeSubpath()
    return p
}

func drawIcon(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let px = CGFloat(pixels)

    // Work on a 100 unit canvas with y pointing down.
    ctx.translateBy(x: 0, y: px)
    ctx.scaleBy(x: px / 100, y: -px / 100)

    // Tile: a blue gradient, lighter at the top, with a faint light edge.
    let tile = CGPath(roundedRect: CGRect(x: 9.57, y: 9.57, width: 80.86, height: 80.86),
                      cornerWidth: 18.1, cornerHeight: 18.1, transform: nil)
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [CGColor(red: 0.31, green: 0.49, blue: 0.94, alpha: 1),
                 CGColor(red: 0.17, green: 0.28, blue: 0.72, alpha: 1)] as CFArray,
        locations: [0, 1])!
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 50, y: 9.57),
                           end: CGPoint(x: 50, y: 90.43), options: [])
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tile.copy(strokingWithWidth: 1, lineCap: .butt, lineJoin: .round, miterLimit: 4))
    ctx.addPath(tile)
    ctx.clip(using: .evenOdd) // only the inner half of the stroke
    ctx.addPath(tile)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
    ctx.setLineWidth(1)
    ctx.strokePath()
    ctx.restoreGState()

    // Pin: tilted as if pushed in, with a soft shadow below it. A shadow's
    // offset is in device space, where y points up, hence the minus.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -px * 0.012), blur: px * 0.024,
                  color: CGColor(gray: 0, alpha: 0.28))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.translateBy(x: 23, y: 22)
    ctx.scaleBy(x: 2.25, y: 2.25)
    ctx.translateBy(x: 12, y: 12)
    ctx.rotate(by: 32 * .pi / 180)
    ctx.translateBy(x: -12, y: -12)
    ctx.setFillColor(.white)
    ctx.setStrokeColor(.white)
    ctx.setLineWidth(1.2)
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    ctx.addPath(pinBody())
    ctx.drawPath(using: .fillStroke)
    ctx.move(to: CGPoint(x: 12, y: 14.25))
    ctx.addLine(to: CGPoint(x: 12, y: 20.5))
    ctx.strokePath()
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("Perch.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    try! drawIcon(pixels: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try! drawIcon(pixels: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
try? fm.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote Resources/AppIcon.icns")
