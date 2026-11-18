#!/bin/sh
# Renders the menu bar robin straight from Sources/MenuBarGlyph.swift, so a
# change to its shapes can be checked before building the app:
#
#     scripts/glyph-preview.sh
#
# Writes .build/glyph-preview/glyphs.png (each state large on the 24 unit
# grid, at real size in light and dark menu bars, and on the title bar
# buttons) and flying.svg and perched.svg, for editing in a vector editor.
# Copy edited path data back into MenuBarGlyph.Shape. See docs/branding.
set -e
cd "$(dirname "$0")/.."
OUT=.build/glyph-preview
mkdir -p "$OUT"
cat > "$OUT/main.swift" <<'EOF'
import AppKit

let out = CommandLine.arguments[1]
let big = 192.0, pad = 16.0
let width = pad + 4 * (big + pad), height = big + 2 * pad + 150
let scale = 2.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()

// Large, on the grid: flying and perched, in black and in white on dark.
for (i, (pinned, dark)) in [(false, false), (true, false), (false, true), (true, true)].enumerated() {
    let r = NSRect(x: pad + Double(i) * (big + pad), y: height - pad - big, width: big, height: big)
    (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1)).setFill(); r.fill()
    NSColor(white: dark ? 0.3 : 0.85, alpha: 1).setStroke()
    for k in 0...24 where k % 4 == 0 {
        let p = NSBezierPath(); p.lineWidth = 0.5
        p.move(to: NSPoint(x: r.minX + Double(k) * big / 24, y: r.minY)); p.line(to: NSPoint(x: r.minX + Double(k) * big / 24, y: r.maxY))
        p.move(to: NSPoint(x: r.minX, y: r.minY + Double(k) * big / 24)); p.line(to: NSPoint(x: r.maxX, y: r.minY + Double(k) * big / 24))
        p.stroke()
    }
    MenuBarGlyph.draw(in: r, color: dark ? .white : .black, pinned: pinned, warning: false)
}

// Real size in menu bars, then the title bar buttons.
for (row, dark) in [false, true].enumerated() {
    let y = 70.0 - Double(row) * 34
    (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
    NSRect(x: pad, y: y, width: 200, height: 26).fill()
    let ink: NSColor = dark ? .white : NSColor(white: 0, alpha: 0.85)
    for (i, (p, w)) in [(false, false), (true, false), (false, true), (true, true)].enumerated() {
        MenuBarGlyph.draw(in: NSRect(x: pad + 10 + Double(i) * 28, y: y + 4, width: 18, height: 18), color: ink, pinned: p, warning: w)
    }
    let bx = 260.0
    (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
    NSRect(x: bx, y: y, width: 90, height: 26).fill()
    let b1 = NSRect(x: bx + 12, y: y + 2, width: 22, height: 22).insetBy(dx: 1, dy: 1)
    NSColor.gray.withAlphaComponent(0.5).setFill(); NSBezierPath(ovalIn: b1).fill()
    MenuBarGlyph.draw(in: b1.insetBy(dx: 2.5, dy: 2.5), color: .white, pinned: false, warning: false)
    let b2 = NSRect(x: bx + 50, y: y + 2, width: 22, height: 22).insetBy(dx: 1, dy: 1)
    MenuBarGlyph.breast.setFill(); NSBezierPath(ovalIn: b2).fill()
    NSColor(white: 0.13, alpha: 1).setFill(); NSBezierPath(ovalIn: b2.insetBy(dx: 2, dy: 2)).fill()
    MenuBarGlyph.draw(in: b2.insetBy(dx: 3.5, dy: 3.5), color: .white, pinned: true, warning: false)
}
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/glyphs.png"))

// SVGs of the same shapes, y down on the 24 unit grid, as in the source.
for (name, s) in [("flying", MenuBarGlyph.Shape.flying), ("perched", MenuBarGlyph.Shape.perched)] {
    var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\" width=\"480\" height=\"480\">\n"
    svg += "  <path id=\"outline\" d=\"\(s.outline)\" fill=\"#000\"/>\n"
    svg += "  <path id=\"breast\" d=\"\(s.breast)\" fill=\"#F26B1F\"/>\n"
    if let feet = s.feet { svg += "  <path id=\"feet\" d=\"\(feet)\" fill=\"none\" stroke=\"#000\" stroke-width=\"0.9\" stroke-linecap=\"round\"/>\n" }
    svg += "  <path id=\"cut\" d=\"\(s.cut)\" fill=\"none\" stroke=\"#fff\" stroke-width=\"0.6\" stroke-linecap=\"round\"/>\n"
    svg += "  <circle id=\"eye\" cx=\"\(s.eye.x)\" cy=\"\(s.eye.y)\" r=\"\(s.eyeRadius)\" fill=\"#fff\"/>\n</svg>\n"
    try! svg.write(toFile: "\(out)/\(name).svg", atomically: true, encoding: .utf8)
}
print("Wrote \(out)/glyphs.png, flying.svg and perched.svg")
EOF
swiftc -swift-version 6 Sources/MenuBarGlyph.swift "$OUT/main.swift" -o "$OUT/render"
"$OUT/render" "$OUT"
[ -t 1 ] && open "$OUT/glyphs.png" || true
