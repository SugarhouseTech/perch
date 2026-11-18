import AppKit

/// The menu bar pin. Upright and outlined while nothing is pinned; filled,
/// tilted and sunk (a shorter needle) while something is. SF Symbols' `pin`
/// and `pin.fill` differ only in fill, which is hard to tell apart at menu
/// bar size, so the pinned state changes shape too.
///
/// Drawn on a 24 unit grid with y pointing down, the same shape as the app
/// icon (`generate_icon.swift`). Nonisolated so the image's drawing handler
/// can call it wherever AppKit renders.
nonisolated enum MenuBarGlyph {
    static let size = NSSize(width: 18, height: 18)

    static func idle(_ rect: NSRect, _ color: NSColor) {
        draw(in: rect, color: color, pinned: false)
    }

    static func pinned(_ rect: NSRect, _ color: NSColor) {
        draw(in: rect, color: color, pinned: true)
    }

    private static func draw(in rect: NSRect, color: NSColor, pinned: Bool) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let scale = rect.width / 24
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: scale, y: -scale)
        if pinned {
            // Tilted about the centre, and nudged so the shorter pin stays
            // visually centred.
            ctx.translateBy(x: 13.2, y: 13.6)
            ctx.rotate(by: 38 * .pi / 180)
            ctx.translateBy(x: -12, y: -12)
        }
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(1.6)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.addPath(body)
        ctx.drawPath(using: pinned ? .fillStroke : .stroke)
        ctx.move(to: CGPoint(x: 12, y: 14.25))
        ctx.addLine(to: CGPoint(x: 12, y: pinned ? 17.6 : 21))
        ctx.strokePath()
    }

    /// The head, collar and skirt. Built per draw, which costs nothing next
    /// to the drawing itself and needs no shared state.
    private static var body: CGPath {
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
}
