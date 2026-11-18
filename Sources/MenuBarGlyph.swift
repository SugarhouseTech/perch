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

        ctx.setFillColor(color.cgColor)
        ctx.addPath(path(shape.outline))
        ctx.fillPath()
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

        /// Side on, climbing, wings raised; traced from the chosen design.
        static let flying = Shape(
            outline: "M4.12 1.2 L15.5 11.42 C16.28 10.54 17.55 9.86 18.71 9.96 C19.49 10.05 20.08 10.35 21.05 10.93 L22.8 11.12 L20.95 11.9 C20.76 13.36 19.88 14.92 18.71 16.09 C17.74 17.06 15.99 18.32 13.46 19.01 L8.21 19.69 L4.41 22.7 L6.75 20.08 L1.2 21.73 L9.96 16.48 L8.89 11.42 L4.12 8.69 L5.77 6.65 Z",
            breast: "M20.9 12.19 C20.56 13.75 19.78 15.02 18.71 16.09 C18.13 16.67 17.55 17.16 17.06 17.55 L18.03 15.02 C18.71 13.95 19.69 12.88 20.9 12.19 Z",
            cut: "M15.5 12.1 L18.03 15.02",
            eye: CGPoint(x: 19.2, y: 11.12), eyeRadius: 0.55,
            feet: nil)

        /// Settled on a branch, wings folded.
        static let perched = Shape(
            outline: "M1.0 20.7 L5.4 16.1 L16.2 3.9 C16.8 2.8 17.5 2.1 18.2 2.0 C19.0 1.9 19.6 2.1 20.1 2.6 L20.9 3.4 L22.9 3.6 L20.7 4.6 C20.6 5.2 20.6 5.7 20.5 6.2 C20.3 8.0 20.1 9.6 19.9 10.8 C19.6 12.0 19.0 13.0 18.2 13.7 C17.4 14.7 16.6 15.7 15.7 16.4 L10.6 16.8 L2.9 20.9 Z",
            breast: "M20.55 5.0 C20.5 6.2 20.3 8.6 19.9 10.8 C19.6 12.0 19.0 13.0 18.2 13.7 L17.2 11.7 C17.4 10.2 17.6 8.9 17.9 7.8 C18.4 6.6 19.3 5.6 20.55 5.0 Z",
            cut: "M7.4 16.1 L17.2 11.7",
            eye: CGPoint(x: 18.7, y: 3.8), eyeRadius: 0.45,
            feet: "M11.8 17.0 L13.25 19.8 M13.9 17.0 L15.3 19.8 M7.2 20.2 L20.3 20.2")
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
