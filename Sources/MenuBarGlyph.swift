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

    /// - Parameter warning: a permission is missing. An orange dot at the
    ///   top right, cut out of the pin so it reads at menu bar size, says the
    ///   menu has something to fix.
    static func draw(in rect: NSRect, color: NSColor, pinned: Bool, warning: Bool) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawPin(in: ctx, rect: rect, color: color, pinned: pinned)
        if warning { drawWarningDot(in: ctx, rect: rect) }
    }

    private static func drawPin(in ctx: CGContext, rect: NSRect, color: NSColor, pinned: Bool) {
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

    private static func drawWarningDot(in ctx: CGContext, rect: NSRect) {
        let radius = rect.width * 0.16
        let gap = rect.width * 0.07   // the cut-out ring that sets it apart
        let center = CGPoint(x: rect.maxX - radius, y: rect.maxY - radius)
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: CGRect(x: center.x - radius - gap, y: center.y - radius - gap,
                                   width: (radius + gap) * 2, height: (radius + gap) * 2))
        ctx.setBlendMode(.normal)
        ctx.setFillColor(NSColor.systemOrange.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                   width: radius * 2, height: radius * 2))
        ctx.restoreGState()
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
