import CoreGraphics
import Foundation

/// The arithmetic of a pin: what part of its window it shows, where the panel
/// goes, how a point on the panel maps to the window, and how a crop follows a
/// resize. All of it pure, so it can be tested without a window in sight.
///
/// Three coordinate systems meet here, and most of the care is in not mixing
/// them up:
/// - Window points: from the target window's top-left corner, running down.
///   A crop is in these.
/// - Panel points: from the panel's bottom-left corner, running up, as AppKit
///   reports a location in a window.
/// - Screen points: AppKit's global space, from the bottom-left of the primary
///   display, running up. The window list reports frames from the top-left
///   instead, running down; `appKitFrame` converts.
nonisolated enum OverlayGeometry {

    // MARK: - What is shown

    /// The crop, trimmed to the window as it is now. A window made smaller
    /// than its crop shows what is left of it; one that loses the area
    /// entirely keeps the original rectangle, so the pin keeps its size and
    /// shows the window's edge rather than collapsing to nothing.
    static func clampedCrop(_ crop: CGRect?, windowSize: CGSize) -> CGRect? {
        guard let crop else { return nil }
        let trimmed = crop.intersection(CGRect(origin: .zero, size: windowSize))
        return trimmed.isNull || trimmed.width < 1 || trimmed.height < 1 ? crop : trimmed
    }

    /// The part of the window on show, in window points.
    static func shownRect(crop: CGRect?, windowSize: CGSize) -> CGRect {
        clampedCrop(crop, windowSize: windowSize) ?? CGRect(origin: .zero, size: windowSize)
    }

    // MARK: - Panel to window

    /// The point in the target window under a point on the panel, in the
    /// window list's global top-left coordinates. Takes the fraction across
    /// the panel and applies it to the part of the window being shown.
    /// Fractions rather than offsets keep the point right while the two frames
    /// briefly disagree mid-resize.
    ///
    /// A point off the panel has no matching point and gives nil, unless
    /// `clamped`, when it is moved to the nearest edge of the panel first.
    ///
    /// - Parameters:
    ///   - location: in panel points.
    ///   - window: the window's bounds from the window list.
    static func targetPoint(location: CGPoint, panelSize: CGSize, window: CGRect,
                            crop: CGRect?, clamped: Bool) -> CGPoint? {
        guard panelSize.width > 0, panelSize.height > 0 else { return nil }
        var fx = location.x / panelSize.width
        var fyFromTop = (panelSize.height - location.y) / panelSize.height
        if clamped {
            fx = min(max(fx, 0), 1)
            fyFromTop = min(max(fyFromTop, 0), 1)
        }
        guard fx >= 0, fx <= 1, fyFromTop >= 0, fyFromTop <= 1 else { return nil }
        let shown = shownRect(crop: crop, windowSize: window.size)
        return CGPoint(x: window.origin.x + shown.minX + fx * shown.width,
                       y: window.origin.y + shown.minY + fyFromTop * shown.height)
    }

    // MARK: - Drawing a crop

    /// The rectangle an option-drag from `start` to `point` selects, in panel
    /// points, limited to the panel. Null when it misses the panel entirely.
    static func selectionRect(from start: CGPoint, to point: CGPoint, panelSize: CGSize) -> CGRect {
        let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                          width: abs(point.x - start.x), height: abs(point.y - start.y))
        return rect.intersection(CGRect(origin: .zero, size: panelSize))
    }

    /// Whether a selection is a crop rather than an option-click: at least
    /// `minimumSide` both ways.
    static func isCrop(_ selection: CGRect, minimumSide: CGFloat) -> Bool {
        !selection.isNull && selection.width >= minimumSide && selection.height >= minimumSide
    }

    /// The crop a selection on the panel asks for, in window points. Goes
    /// through whatever is on show now, so cropping a cropped pin narrows it
    /// further.
    static func crop(forSelection selection: CGRect, panelSize: CGSize,
                     windowSize: CGSize, current: CGRect?) -> CGRect {
        let shown = shownRect(crop: current, windowSize: windowSize)
        let sx = shown.width / panelSize.width, sy = shown.height / panelSize.height
        // Panel points run up from the bottom; window points run down.
        return roundedToPoints(CGRect(x: shown.minX + selection.minX * sx,
                                      y: shown.minY + (panelSize.height - selection.maxY) * sy,
                                      width: selection.width * sx, height: selection.height * sy))
    }

    /// Each edge to the nearest whole point. Not `integral`, which rounds
    /// outwards: an edge at 140.000000001 from scaling there and back became
    /// 141, so selecting all of a cropped pin widened it by a point.
    static func roundedToPoints(_ r: CGRect) -> CGRect {
        let x0 = r.minX.rounded(), y0 = r.minY.rounded()
        return CGRect(x: x0, y: y0, width: r.maxX.rounded() - x0, height: r.maxY.rounded() - y0)
    }

    // MARK: - Resizing a cropped pin

    /// The crop a resize of the panel from `old` to `new` asks for, and the
    /// panel frame that shows it, both trimmed to the window. The crop moves
    /// the same edges by the same amount, so the pin shows more or less of the
    /// window around what it showed before, at the same scale. Anything past
    /// the window is trimmed, and the panel loses the same amount from the
    /// same edges.
    ///
    /// Nil when there is nothing to do: no previous frame, or no change.
    static func resizedCrop(_ crop: CGRect, from old: CGRect, to new: CGRect,
                            windowSize: CGSize) -> (crop: CGRect, panel: CGRect)? {
        guard old != .zero, old != new else { return nil }
        // Screen points run up, window points run down: the top edge moving
        // up by d moves the crop's top up the window by d.
        let proposed = CGRect(x: crop.minX + (new.minX - old.minX),
                              y: crop.minY + (old.maxY - new.maxY),
                              width: new.width, height: new.height)
        var trimmed = proposed.intersection(CGRect(origin: .zero, size: windowSize))
        // A resize that leaves the window altogether, or keeps only a sliver
        // along its edge, keeps the crop it had rather than shrinking to
        // nothing: an edge exactly on the window's used to give a crop of
        // zero width.
        if trimmed.isNull || trimmed.width < 1 || trimmed.height < 1 { trimmed = crop }
        trimmed = roundedToPoints(trimmed)
        let panel = CGRect(x: new.minX + (trimmed.minX - proposed.minX),
                           y: new.minY + (proposed.maxY - trimmed.maxY),
                           width: trimmed.width, height: trimmed.height)
        return (trimmed, panel)
    }

    // MARK: - Where the panel goes

    /// Over the whole window, over the cropped area of it, or wherever the
    /// user dragged a cropped pin to. All in screen points.
    static func panelFrame(target: CGRect, crop: CGRect?, movedOrigin: CGPoint?) -> CGRect {
        guard let crop = clampedCrop(crop, windowSize: target.size) else { return target }
        if let movedOrigin { return CGRect(origin: movedOrigin, size: crop.size) }
        // Window points run down from the top; screen points run up.
        return CGRect(x: target.minX + crop.minX, y: target.maxY - crop.maxY,
                      width: crop.width, height: crop.height)
    }

    /// A window's frame in AppKit's screen points, from its bounds in the
    /// window list, which run down from the top of the primary display.
    static func appKitFrame(fromWindowList bounds: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: bounds.minX, y: primaryHeight - bounds.minY - bounds.height,
               width: bounds.width, height: bounds.height)
    }

    /// The bounds in a window-list entry's `kCGWindowBounds` dictionary.
    static func bounds(fromWindowList entry: [String: CGFloat]) -> CGRect {
        CGRect(x: entry["X"] ?? 0, y: entry["Y"] ?? 0,
               width: entry["Width"] ?? 0, height: entry["Height"] ?? 0)
    }

    // MARK: - The stream

    /// What the stream must be configured for: the filmed area's origin and
    /// the panel's size, which is the stream's output size in points. A change
    /// in either means reconfiguring it.
    static func streamGeometry(crop: CGRect?, windowSize: CGSize, panelSize: CGSize) -> CGRect {
        CGRect(origin: shownRect(crop: crop, windowSize: windowSize).origin, size: panelSize)
    }

    /// The stream's output in pixels: the panel at the display's scale, and
    /// never nothing.
    static func outputPixels(panelSize: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        (max(Int(panelSize.width * scale), 1), max(Int(panelSize.height * scale), 1))
    }

    /// Frames in flight. Each is a whole window of pixels: about 57 MB for a
    /// 5K-wide window at 2x. Five is smooth headroom for ordinary windows; a
    /// very large one keeps the minimum, as the frame on screen is held
    /// separately and cannot be overwritten.
    static func queueDepth(width: Int, height: Int) -> Int {
        width * height > 6_000_000 ? 3 : 5
    }

    /// The backing scale of the display holding most of `rect`, or nil when
    /// it is on none of them.
    static func scale(under rect: CGRect, displays: [(frame: CGRect, scale: CGFloat)]) -> CGFloat? {
        let best = displays.max { a, b in
            let ia = a.frame.intersection(rect), ib = b.frame.intersection(rect)
            return area(ia) < area(ib)
        }
        guard let best, best.frame.intersects(rect) else { return nil }
        return best.scale
    }

    private static func area(_ r: CGRect) -> CGFloat {
        r.isNull ? 0 : r.width * r.height
    }

    // MARK: - The frame on show during a change

    /// Until the stream sends a frame of a new area, the part of the frame
    /// already on the layer that shows it: `new` within `old` as a unit
    /// rectangle (bottom-left origin, as a layer's contents rectangle is),
    /// composed with the part already shown.
    ///
    /// Nil when the old frame cannot show the new area, as when a crop is
    /// cleared: the pin is left empty for that moment rather than stretched.
    static func contentsRect(current: CGRect, from old: CGRect, to new: CGRect) -> CGRect? {
        guard old.width > 0, old.height > 0, old.contains(new) else { return nil }
        let ux = (new.minX - old.minX) / old.width
        let uy = (old.maxY - new.maxY) / old.height
        let uw = new.width / old.width, uh = new.height / old.height
        return CGRect(x: current.minX + ux * current.width,
                      y: current.minY + uy * current.height,
                      width: uw * current.width, height: uh * current.height)
    }

    // MARK: - Moving a cropped pin

    /// Whether a press has travelled far enough to be a move rather than a click.
    static func isMove(dx: CGFloat, dy: CGFloat, threshold: CGFloat) -> Bool {
        hypot(dx, dy) >= threshold
    }
}
