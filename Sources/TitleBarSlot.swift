import AppKit
import ApplicationServices

/// Where along a window's title bar a pin badge can sit without covering one
/// of the window's own controls.
///
/// The badge belongs in the top-right corner, but plenty of apps keep a
/// button there: Safari's tab overview, Chrome's tab search, Finder's search
/// field. So before placing it, ask the app what lies under each spot along the
/// title bar, working leftwards from the corner, and take the first spot clear
/// of anything clickable.
enum TitleBarSlot {

    /// What lies under one point of the title bar.
    enum Probe {
        /// Title text, toolbar background, the window itself: safe to cover.
        case free
        /// A button, field, tab or other control.
        case taken
        /// The app did not answer. Stop asking it.
        case failed
    }

    /// Distance from the window's right edge to the badge when nothing is in the way.
    static let margin: CGFloat = 8
    /// Spacing between the points asked about.
    static let step: CGFloat = 4
    /// Never ask more than this many points about one window.
    static let maxProbes = 64

    /// The distance from the window's right edge to the badge's right edge, or
    /// nil if no clear spot was found and the badge should take the corner as
    /// before.
    ///
    /// - Parameters:
    ///   - side: the badge's width.
    ///   - width: the window's width. The badge stays in its right half.
    ///   - probe: what lies under the point this far from the window's right edge.
    static func inset(side: CGFloat, width: CGFloat, probe: (CGFloat) -> Probe) -> CGFloat? {
        // A spot is clear when every point across the badge's width is.
        let span = Int((side / step).rounded(.down))
        let limit = min(width / 2, 400)
        var memo: [Int: Probe] = [:]
        var asked = 0

        func result(_ k: Int) -> Probe {
            if let known = memo[k] { return known }
            guard asked < maxProbes else { return .failed }
            asked += 1
            let p = probe(margin + CGFloat(k) * step)
            memo[k] = p
            return p
        }

        var start = 0
        scan: while margin + CGFloat(start) * step + side <= limit {
            // Check the far side first: when it is taken, the scan can skip
            // straight past it.
            for k in stride(from: start + span, through: start, by: -1) {
                switch result(k) {
                case .failed: return nil
                case .taken:
                    start = k + 1
                    continue scan
                case .free: break
                }
            }
            return margin + CGFloat(start) * step
        }
        return nil
    }
}

/// Finds and remembers a clear spot for the badge on each window, asking the
/// window's app through Accessibility.
///
/// An answer that saw no control at all is only provisional. Chromium and
/// Electron apps (Chrome, Discord, Slack, VS Code) build the accessibility
/// tree for their web content lazily: the first question only wakes it, and
/// the buttons appear a moment later. Until then every point along the title
/// bar looks free. So such an answer is asked again a few times, further apart
/// each time, before it is believed. A slow app that times out gets the same
/// treatment.
final class TitleBarSlotFinder {

    struct Entry {
        /// The size measured, and the answer for it.
        let size: CGSize
        let spot: BadgeSpot
        /// The app named at least one control and answered every question:
        /// the spot is final for this size.
        let sure: Bool
        /// How many times this size has been measured.
        let tries: Int
        let measuredAt: TimeInterval
        var usedAt: TimeInterval
        /// The size the window last had, and since when. A window that has
        /// not held still is not measured yet.
        var seenSize: CGSize
        var seenSince: TimeInterval
        /// When the window first left the measured size, if it has.
        var driftSince: TimeInterval?

        init(size: CGSize, spot: BadgeSpot, sure: Bool, tries: Int, at now: TimeInterval) {
            self.size = size
            self.spot = spot
            self.sure = sure
            self.tries = tries
            measuredAt = now
            usedAt = now
            seenSize = size
            seenSince = now
        }

        /// Note the window's current size.
        mutating func see(_ current: CGSize, at now: TimeInterval) {
            usedAt = now
            if current != seenSize {
                seenSize = current
                seenSince = now
            }
            if current == size {
                driftSince = nil
            } else if driftSince == nil {
                driftSince = now
            }
        }
    }

    /// How many times a provisional answer is asked again before it is kept.
    static let maxTries = 4
    /// Remember this many windows; the least recently used is forgotten.
    static let capacity = 32
    /// A resized window is measured once its size has held this long, so an
    /// animated resize (a window manager, zoom, tiling) is measured once at
    /// the end rather than at every step.
    static let settle: TimeInterval = 0.2
    /// A window still changing size after this long is left until it stops,
    /// rather than kept under watch.
    static let driftWatch: TimeInterval = 3
    /// The most time one measurement may spend asking an app, on the main thread.
    static let budget: TimeInterval = 0.25

    private var cache: [UInt32: Entry] = [:]

    /// Set while placing badges when a window's answer is not settled yet, so
    /// the caller keeps checking for a moment longer.
    private(set) var recheckWanted = false

    /// Roles a click is meant for. Covering one of these takes its clicks.
    private static let controls: Set<String> = [
        kAXButtonRole, kAXTextFieldRole, kAXTextAreaRole, kAXPopUpButtonRole,
        kAXMenuButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXRadioGroupRole,
        kAXComboBoxRole, kAXSliderRole, kAXIncrementorRole, kAXDisclosureTriangleRole,
        "AXLink", "AXTab", "AXSegmentedControl",
    ]

    /// Roles that end the walk up from a hit: past these, everything is the
    /// window's own surface.
    private static let surfaces: Set<String> = [
        kAXWindowRole, kAXToolbarRole, kAXApplicationRole, kAXSheetRole, kAXDrawerRole,
    ]

    /// Wait this long after a provisional answer before asking again.
    static func recheckDelay(afterTries tries: Int) -> TimeInterval {
        0.3 * pow(2, Double(max(tries - 1, 0)))
    }

    /// Whether to ask the app again, given what is known (already updated
    /// with the window's current size).
    ///
    /// While a mouse button is held, a window being resized keeps its last
    /// answer instead of being asked on every step of the drag.
    static func shouldMeasure(_ entry: Entry?, now: TimeInterval, dragging: Bool) -> Bool {
        guard let entry else { return true }
        if dragging { return false }
        if entry.seenSize != entry.size { return now - entry.seenSince >= settle }
        if entry.sure || entry.tries >= maxTries { return false }
        return now - entry.measuredAt >= recheckDelay(afterTries: entry.tries)
    }

    /// Whether the answer will change by itself soon, so it is worth checking
    /// again shortly even if nothing else happens.
    static func wantsRecheck(_ entry: Entry, now: TimeInterval) -> Bool {
        if let drift = entry.driftSince { return now - drift < driftWatch }
        return !entry.sure && entry.tries < maxTries
    }

    /// Clear `recheckWanted` before placing a round of badges.
    func beginPass() { recheckWanted = false }

    /// Where on the window to place the badge.
    func spot(pid: pid_t, windowID: UInt32, frame: NSRect, side: CGFloat) -> BadgeSpot {
        let now = ProcessInfo.processInfo.systemUptime
        var old = cache[windowID]
        old?.see(frame.size, at: now)
        var entry: Entry
        if Self.shouldMeasure(old, now: now, dragging: NSEvent.pressedMouseButtons != 0) {
            let tries = old.map { $0.size == frame.size ? $0.tries + 1 : 1 } ?? 1
            let (spot, sure) = measure(pid: pid, windowID: windowID, frame: frame, side: side, attempt: tries)
            entry = Entry(size: frame.size, spot: spot, sure: sure, tries: tries, at: now)
            if old == nil, cache.count >= Self.capacity,
               let oldest = cache.min(by: { $0.value.usedAt < $1.value.usedAt })?.key {
                cache[oldest] = nil
            }
        } else {
            entry = old!
        }
        cache[windowID] = entry
        if Self.wantsRecheck(entry, now: now) { recheckWanted = true }
        return entry.spot
    }

    /// The last answer for a window, without asking again.
    /// Counts as a use, so a pin showing its floating copy for hours keeps
    /// its answer while other windows come and go.
    func knownSpot(windowID: UInt32) -> (size: CGSize, spot: BadgeSpot)? {
        cache[windowID]?.usedAt = ProcessInfo.processInfo.systemUptime
        return cache[windowID].map { ($0.size, $0.spot) }
    }

    /// Ask the app where the badge can go, and whether the answer can be trusted.
    private func measure(pid: pid_t, windowID: UInt32, frame: NSRect, side: CGFloat,
                         attempt: Int) -> (BadgeSpot, sure: Bool) {
        guard let primary = NSScreen.screens.first else { return (.corner, true) }
        let app = AXUIElementCreateApplication(pid)
        // On the main thread: never wait long on a slow app.
        AXUIElementSetMessagingTimeout(app, 0.1)
        // Accessibility positions are top-left based, from the primary screen.
        let windowTop = primary.frame.height - frame.maxY

        // Line the badge up with the close button. Its middle is the line a
        // title bar's contents are centred on, however tall the bar is: a plain
        // title bar, a tall unified toolbar, a browser's tab strip.
        var top = BadgeSpot.corner.top
        let deadline = ProcessInfo.processInfo.systemUptime + Self.budget
        if let window = WindowLevelManager.axWindow(pid: pid, windowID: windowID, timeout: 0.1),
           let mid = Self.closeButtonMidY(of: window) {
            top = BadgeSpot.top(centredOn: mid - windowTop, side: side)
        }
        let y = Float(windowTop + top + side / 2)
        var log: [String] = []
        var failed = false
        var seen: Set<String> = []

        let inset = TitleBarSlot.inset(side: side, width: frame.width) { fromRight in
            // A slow app is not allowed to hold up the main thread: an answer
            // that ran out of time counts as none, and is asked again later.
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                log.append("\(Int(fromRight)):budget")
                failed = true
                return .failed
            }
            let x = Float(frame.maxX - fromRight)
            var hit: AXUIElement?
            let err = AXUIElementCopyElementAtPosition(app, x, y, &hit)
            switch err {
            case .success:
                guard let hit else { return .free }
                let (probe, role) = Self.classify(hit)
                if probe == .taken { log.append("\(Int(fromRight)):\(role)") } else { seen.insert(role) }
                return probe
            case .noValue, .attributeUnsupported:
                return .free
            default:
                log.append("\(Int(fromRight)):err\(err.rawValue)")
                failed = true
                return .failed
            }
        }
        // Seeing no control at all is what an app whose tree is not built yet
        // looks like, as much as an empty title bar.
        let sure = !failed && !log.isEmpty
        wplog("titlebar slot wid=\(windowID) pid=\(pid) try=\(attempt) width=\(Int(frame.width)) top=\(Int(top)) inset=\(inset.map { "\(Int($0))" } ?? "default") sure=\(sure) taken=[\(log.joined(separator: " "))] free=[\(seen.sorted().joined(separator: " "))]")
        return (BadgeSpot(right: inset ?? TitleBarSlot.margin, top: top), sure)
    }

    /// The vertical middle of a window's close button, in screen coordinates.
    private static func closeButtonMidY(of window: AXUIElement) -> CGFloat? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &ref) == .success,
              let button = WindowLevelManager.element(from: ref) else { return nil }
        AXUIElementSetMessagingTimeout(button, 0.1)
        var pos: AnyObject?, size: AnyObject?
        guard AXUIElementCopyAttributeValue(button, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(button, kAXSizeAttribute as CFString, &size) == .success,
              let p = WindowLevelManager.point(from: pos), let s = WindowLevelManager.size(from: size),
              s.height > 0 else { return nil }
        return p.y + s.height / 2
    }

    /// Whether a hit element is a control, looking up through its parents, as
    /// the hit is often a button's image or label rather than the button.
    private static func classify(_ element: AXUIElement) -> (TitleBarSlot.Probe, String) {
        var current: AXUIElement? = element
        for _ in 0..<5 {
            guard let el = current else { break }
            // Elements an app hands back carry the default wait of several
            // seconds, not the app's.
            AXUIElementSetMessagingTimeout(el, 0.1)
            guard let role = string(el, kAXRoleAttribute) else { break }
            if controls.contains(role) { return (.taken, role) }
            if surfaces.contains(role) { return (.free, role) }
            var parent: AnyObject?
            guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parent) == .success else { break }
            current = WindowLevelManager.element(from: parent)
        }
        return (.free, "")
    }

    private static func string(_ el: AXUIElement, _ attribute: String) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}

/// Where a badge sits on its window.
struct BadgeSpot: Equatable {
    /// Distance from the window's right edge to the badge's right edge.
    var right: CGFloat
    /// Distance from the window's top edge to the badge's top edge.
    var top: CGFloat

    /// The top-right corner, for a window that cannot be asked.
    static let corner = BadgeSpot(right: TitleBarSlot.margin, top: 4)

    /// The badge's top edge for its middle to sit `mid` below the window's
    /// top edge. A close button reported somewhere odd keeps the badge within
    /// the title bar region rather than following it down the window.
    static func top(centredOn mid: CGFloat, side: CGFloat) -> CGFloat {
        guard mid.isFinite, mid > side / 2, mid < 48 else { return corner.top }
        return (mid - side / 2).rounded()
    }

    /// The same spot on a copy of the window drawn at another size.
    func scaled(by factor: CGFloat) -> BadgeSpot {
        BadgeSpot(right: right * factor, top: top * factor)
    }
}
