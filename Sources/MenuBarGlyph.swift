import AppKit

/// The menu bar robin. In flight, seen from the side, while nothing is
/// perched; settled on a branch while something is. The two states differ in
/// shape, not just fill, so the state reads at a glance. It faces left: the
/// perch button sits at the right of a title bar, and the bird looks along
/// the bar towards it.
///
/// The bird is drawn in the menu bar's own ink with one touch of colour, the
/// robin's orange breast, and its eye cut out. Drawn on a 24 unit grid with y pointing down. Nonisolated so the
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

        if warning { drawWarningDot(in: ctx, rect: rect, left: !pinned) }
        ctx.endTransparencyLayer()
    }

    /// Top left, or top right on the perched bird, whose head is top left.
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
        /// A line cut out of the bird, if it has one.
        let cut: String
        let eye: CGPoint
        let eyeRadius: CGFloat
        let feet: String?

        /// Side on, round bodied, one wing raised with scalloped feather
        /// tips, and a straight tail.
        static let flying = Shape(
            outline: "M20.2 21.5 L22.8 19.9 C20.9 18.8 18.5 17.5 17.1 16.6 C15.7 15.6 15.3 15.1 14.5 14.4 C14.9 14.3 15.3 14.2 15.7 14.1 C16.1 14 16.5 13.8 16.7 13.6 C17 13.4 17 13.2 17.2 13 L16.8 12.6 C17.3 12.4 17.8 12.3 18.1 12.1 C18.5 11.9 18.6 11.6 18.9 11.4 L18.9 11.1 L18.3 10.8 C18.7 10.5 19.3 10.3 19.6 10 C19.9 9.7 20.1 9.4 20.3 9.2 C20.4 8.9 20.3 8.8 20.3 8.6 L19.3 8.7 C19.6 8.4 20 8 20.2 7.8 C20.5 7.5 20.5 7.4 20.7 7.1 C20.8 6.9 21 6.5 21.1 6.1 C21.2 5.8 21.1 5.6 21.1 5.3 L20.9 5.2 L19.2 6.1 C19.6 5.6 20.1 4.9 20.3 4.4 C20.5 4 20.4 3.8 20.5 3.4 C20.5 3.1 20.4 2.8 20.4 2.5 C17.7 4.1 13.8 6.5 12.3 7.5 C10.7 8.5 11.4 8.3 11 8.7 C10.6 9.2 10.3 9.6 10 10 C9.5 9.4 8.9 8.5 8.5 8.1 C8 7.7 7.8 7.7 7.4 7.6 C7.1 7.4 6.7 7.4 6.4 7.4 C6.1 7.3 5.7 7.4 5.4 7.5 C5.1 7.6 4.8 7.7 4.5 7.9 C4.3 8.1 4.1 8.2 3.9 8.5 C3.7 8.7 3.5 9.1 3.2 9.4 L1.2 10 C1.9 10.3 2.8 10.7 3.2 11 C3.6 11.3 3.6 11.5 3.8 11.9 C4 12.3 4 12.9 4.2 13.4 C4.4 14 4.8 14.8 5.2 15.3 C5.5 15.9 5.7 16.1 6.1 16.6 C6.5 17 7.2 17.6 7.7 17.9 C8.3 18.3 8.8 18.6 9.4 18.8 C10.1 19 11 19.2 11.8 19.2 C12.5 19.3 13.3 19.2 14 19.1 C14.7 18.9 15.4 18.6 16.1 18.4 L20.2 21.5 Z",
            breast: "M9 18.6 C9.1 18.3 9.2 18.3 9.2 17.9 C9.3 17.5 9.2 16.5 9.1 16 C9.1 15.5 9 15.3 8.8 14.9 C8.6 14.4 8.2 13.8 7.9 13.4 C7.7 13 7.5 12.8 7.1 12.6 C6.8 12.3 6.2 12 5.8 11.8 C5.4 11.7 5 11.7 4.6 11.7 C4.3 11.7 4.1 11.9 3.8 11.9 C3.8 12.1 3.8 12.2 3.9 12.6 C4 12.9 4.2 13.6 4.5 14.2 C4.8 14.8 5.3 15.6 5.7 16.1 C6.2 16.7 6.7 17.2 7.2 17.6 C7.8 18 8.4 18.2 9 18.6 Z",
            cut: "",
            eye: CGPoint(x: 5.6, y: 9.7), eyeRadius: 0.51,
            feet: nil)

        /// Settled on a branch: round head, folded wing, tail down behind,
        /// each set apart from the breast by a gap.
        static let perched = Shape(
            outline: "M15.2 16.8 C17.3 17.6 17.9 16.8 19.3 16.8 L19.4 16.7 C18.4 15.1 17.9 13.5 16.5 11.8 C15.2 10.2 13 8.4 11.2 6.6 C11.1 6 11 5.2 10.8 4.8 C10.7 4.4 10.5 4.3 10.4 4 C10.2 3.8 10 3.6 9.7 3.4 C9.5 3.2 9.2 3 8.9 2.8 C8.6 2.7 8.3 2.5 7.8 2.5 C7.4 2.4 6.7 2.5 6.3 2.5 C5.8 2.6 5.6 2.7 5.3 2.9 C5.1 3 5 3 4.7 3.3 C4.4 3.6 3.9 4.3 3.6 4.8 L1.2 5.6 L3.4 6.5 L3.9 7.7 L5.9 8.5 L7.2 12.1 C9.9 13.6 13.2 16 15.2 16.8 Z M21.8 21.6 C22.5 21.6 22.4 21.6 22.7 21.6 L22.8 21.4 L18.7 17.4 L15.7 17.3 L18.9 21.5 C19.8 21.5 21.2 21.6 21.8 21.6 Z",
            breast: "M14 17.3 C15.1 17.3 14.5 17.3 14.7 17.3 L14.7 17.2 L6.7 12.4 L5.4 8.9 C5 8.8 4.4 8.5 4.1 8.4 C3.9 8.3 3.9 8.4 3.8 8.5 C3.8 9.5 3.7 11 3.7 11.7 C3.7 12.5 3.8 12.6 3.9 13 C4.1 13.4 4.3 13.8 4.6 14.3 C4.9 14.7 5.4 15.3 5.8 15.7 C6.2 16.1 6.7 16.4 7.1 16.6 C7.5 16.9 7.3 17.2 8.4 17.3 C9.6 17.4 13 17.3 14 17.3 Z",
            cut: "",
            eye: CGPoint(x: 6.2, y: 5.2), eyeRadius: 0.64,
            feet: "M11.9 17.9 L10.9 20.2 M9.3 17.9 L8.3 20.2 M15.4 20.2 L2.3 20.2")
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
