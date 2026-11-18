import AppKit

/// The menu bar robin. In flight, seen from the side and climbing, while
/// nothing is perched; settled on a branch while something is. The two states
/// differ in shape, not just fill, so the state reads at a glance.
///
/// The bird is drawn in the menu bar's own ink with one touch of colour, the
/// robin's orange breast; a white cut separates head from wing and marks the
/// eye. Drawn on a 24 unit grid with y pointing down. Nonisolated so the
/// image's drawing handler can call it wherever AppKit renders.
nonisolated enum MenuBarGlyph {
    static let size = NSSize(width: 18, height: 18)

    /// The robin's breast.
    static let breast = NSColor(srgbRed: 0.949, green: 0.420, blue: 0.122, alpha: 1)

    /// - Parameter warning: a permission is missing. A red dot in a top
    ///   corner, cut out of the bird so it reads at menu bar size, says the
    ///   menu has something to fix. Red rather than orange, which the breast
    ///   already is.
    static func draw(in rect: NSRect, color: NSColor, pinned: Bool, warning: Bool) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let shape = pinned ? Shape.perched : Shape.flying
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // One layer, so the cuts clear the bird and nothing behind it.
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.saveGState()
        let scale = rect.width / 24
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: scale, y: -scale)

        // Each part (body, wing, tail) is filled on its own, so parts that
        // overlap add up whichever way they were drawn.
        ctx.setFillColor(color.cgColor)
        for part in shape.outline.split(separator: "M") {
            ctx.addPath(path("M" + part))
            ctx.fillPath()
        }
        ctx.setFillColor(breast.cgColor)
        ctx.addPath(path(shape.breast))
        ctx.fillPath()

        ctx.setLineCap(.round)
        if let feet = shape.feet {
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(0.9)
            ctx.addPath(path(feet))
            ctx.strokePath()
        }

        ctx.setBlendMode(.clear)
        ctx.setLineWidth(0.6)
        ctx.addPath(path(shape.cut))
        ctx.strokePath()
        ctx.fillEllipse(in: CGRect(x: shape.eye.x - shape.eyeRadius, y: shape.eye.y - shape.eyeRadius,
                                   width: shape.eyeRadius * 2, height: shape.eyeRadius * 2))
        ctx.restoreGState()

        if warning { drawWarningDot(in: ctx, rect: rect, left: pinned) }
        ctx.endTransparencyLayer()
    }

    /// Top right, or top left on the perched bird, whose head is top right.
    private static func drawWarningDot(in ctx: CGContext, rect: NSRect, left: Bool) {
        let radius = rect.width * 0.16
        let gap = rect.width * 0.07   // the cut-out ring that sets it apart
        let center = CGPoint(x: left ? rect.minX + radius : rect.maxX - radius, y: rect.maxY - radius)
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: CGRect(x: center.x - radius - gap, y: center.y - radius - gap,
                                   width: (radius + gap) * 2, height: (radius + gap) * 2))
        ctx.setBlendMode(.normal)
        ctx.setFillColor(NSColor.systemRed.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                   width: radius * 2, height: radius * 2))
        ctx.restoreGState()
    }

    // MARK: - The two birds

    struct Shape {
        let outline: String
        let breast: String
        /// The white line between head and wing.
        let cut: String
        let eye: CGPoint
        let eyeRadius: CGFloat
        let feet: String?

        /// Side on, climbing, one swept wing raised, feather tips at its
        /// trailing edge, and a forked tail.
        static let flying = Shape(
            outline: "M8.4 19.6 C10.5 17.2 13.5 14.6 16.6 12.6 C17.2 11.0 18.4 9.9 19.6 10.0 C20.4 10.0 21.0 10.4 21.4 10.9 L23.4 11.1 L21.5 11.7 C21.4 14.0 19.6 16.6 16.4 18.2 C13.6 19.6 10.8 20.0 8.4 19.6 Z M9.4 18.9 L2.2 21.6 L5.6 20.9 L4.2 23.4 L10.2 20.2 Z M15.4 13.4 C13.8 9.8 10.8 5.8 6.4 2.4 C7.0 4.3 7.8 5.7 8.9 6.7 L7.8 6.9 C8.6 8.3 9.5 9.4 10.6 10.2 L9.5 10.5 C10.2 11.9 10.9 13.1 11.8 14.2 C12.9 15.3 14.1 15.2 15.4 13.4 Z",
            breast: "M21.45 12.0 C21.2 14.2 19.6 16.5 16.8 18.0 C17.6 16.2 19.0 13.6 21.45 12.0 Z",
            cut: "M17.0 12.0 L15.5 14.0",
            eye: CGPoint(x: 20.0, y: 11.2), eyeRadius: 0.5,
            feet: nil)

        /// Settled on a branch: round head, curved back, wing folded (the
        /// cut), tail down behind.
        static let perched = Shape(
            outline: "M8.8 15.6 C10.6 12.6 13.0 9.4 15.4 6.4 C15.8 4.6 17.0 3.6 18.3 3.7 C19.3 3.8 20.0 4.4 20.4 5.0 L22.6 5.3 L20.5 6.0 C20.9 8.4 20.4 11.6 18.6 13.8 C16.8 15.8 13.8 16.6 11.0 16.4 C9.8 16.3 9.0 16.0 8.8 15.6 Z M10.2 15.0 L2.6 20.6 L4.2 21.4 L11.8 16.4 Z",
            breast: "M20.5 6.3 C20.8 8.6 20.2 11.6 18.6 13.8 C17.6 12.4 17.4 10.4 17.8 8.6 C18.2 7.3 19.2 6.6 20.5 6.3 Z",
            cut: "M9.8 15.0 C12.8 13.8 15.6 12.0 17.4 9.4",
            eye: CGPoint(x: 18.6, y: 5.2), eyeRadius: 0.45,
            feet: "M13.4 16.5 L14.4 19.6 M15.4 16.2 L16.2 19.6 M8.6 19.8 L21.0 19.8")
    }

    /// A path from absolute SVG-style commands (M, L, C, Z), which is how the
    /// shapes above were drawn and checked.
    static func path(_ d: String) -> CGPath {
        let p = CGMutablePath()
        // Letters may sit right against their numbers ("M4.1"): space them out.
        var spaced = ""
        for ch in d { if ch.isLetter { spaced += " \(ch) " } else { spaced.append(ch == "," ? " " : ch) } }
        var tokens = spaced.split(whereSeparator: { $0 == " " }).map(String.init)[...]
        func point() -> CGPoint? {
            guard let x = tokens.popFirst().flatMap(Double.init),
                  let y = tokens.popFirst().flatMap(Double.init) else { return nil }
            return CGPoint(x: x, y: y)
        }
        var command = "M"
        while let first = tokens.first {
            if let letter = first.first, letter.isLetter, first.count == 1 {
                command = first
                tokens.removeFirst()
                if command == "Z" { p.closeSubpath(); continue }
            }
            switch command {
            case "M": if let a = point() { p.move(to: a) }; command = "L"
            case "L": if let a = point() { p.addLine(to: a) }
            case "C":
                if let c1 = point(), let c2 = point(), let e = point() { p.addCurve(to: e, control1: c1, control2: c2) }
            default: tokens.removeFirst()
            }
        }
        return p
    }
}
