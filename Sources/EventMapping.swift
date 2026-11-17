import AppKit

/// The decisions EventForwarder makes about an event, as plain functions over
/// event types, flags and numbers. They have no NSEvent or CGEvent in their
/// signatures so a test can cover every case without posting anything.
enum EventMapping {

    /// Round a scroll delta to whole steps without losing sub-step ticks: a
    /// slow trackpad drag reports fractions of a line, and rounding those to
    /// zero would swallow the whole gesture. Sign is kept.
    ///
    /// Not safe for |delta| beyond Int32 range or NaN: `Int32(_:)` traps there.
    /// Real devices never report such values, so the behaviour is left as it was.
    static func scrollSteps(_ delta: CGFloat) -> Int32 {
        if delta == 0 { return 0 }
        let rounded = Int32(delta.rounded())
        return rounded != 0 ? rounded : (delta > 0 ? 1 : -1)
    }

    /// Only the four modifiers a target app acts on are carried across; caps
    /// lock, fn and the like are dropped.
    static func cgFlags(_ ns: NSEvent.ModifierFlags) -> CGEventFlags {
        var cg: CGEventFlags = []
        if ns.contains(.command) { cg.insert(.maskCommand) }
        if ns.contains(.control) { cg.insert(.maskControl) }
        if ns.contains(.option) { cg.insert(.maskAlternate) }
        if ns.contains(.shift) { cg.insert(.maskShift) }
        return cg
    }

    /// The CGEvent type and button for a mouse event type, or nil for anything
    /// that is not a button event (scrolls, moves, keys). Every "other" button
    /// is posted as `.center`; the real button number is stamped separately.
    static func mouseType(for type: NSEvent.EventType) -> (CGEventType, CGMouseButton)? {
        switch type {
        case .leftMouseDown: return (.leftMouseDown, .left)
        case .leftMouseUp: return (.leftMouseUp, .left)
        case .leftMouseDragged: return (.leftMouseDragged, .left)
        case .rightMouseDown: return (.rightMouseDown, .right)
        case .rightMouseUp: return (.rightMouseUp, .right)
        case .rightMouseDragged: return (.rightMouseDragged, .right)
        case .otherMouseDown: return (.otherMouseDown, .center)
        case .otherMouseUp: return (.otherMouseUp, .center)
        case .otherMouseDragged: return (.otherMouseDragged, .center)
        default: return nil
        }
    }

    /// Whether a CGEvent type carries a button number that must be stamped.
    static func carriesButtonNumber(_ type: CGEventType) -> Bool {
        type == .otherMouseDown || type == .otherMouseUp || type == .otherMouseDragged
    }

    /// Drags and releases keep arriving after the pointer leaves the overlay,
    /// and must still be delivered: a release dropped there would leave the
    /// target app mid-drag with its button held. Those go to the nearest point
    /// on the overlay's edge. Presses and everything else are not clamped, so
    /// a click outside the overlay is ignored rather than moved onto it.
    static func clampsToOverlay(_ type: NSEvent.EventType) -> Bool {
        switch type {
        case .leftMouseDragged, .leftMouseUp, .rightMouseDragged, .rightMouseUp,
             .otherMouseDragged, .otherMouseUp:
            return true
        default:
            return false
        }
    }
}
