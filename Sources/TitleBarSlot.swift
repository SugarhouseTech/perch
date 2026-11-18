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
nonisolated enum TitleBarSlot {

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
///
/// The tree also fills in piece by piece, and flickers while it does: a
/// freshly started Discord has answered nothing, then only its help button
/// (which put the badge between that and the inbox button beside it), then
/// nothing again, the whole tree only seconds after the first question. No
/// single answer from such an app can be trusted to be whole, so it is asked
/// the full number of times, a few seconds in all, and the badge keeps clear
/// of every control any of the answers named.
final class TitleBarSlotFinder {

    nonisolated struct Entry {
        /// The size measured, and the answer for it.
        let size: CGSize
        let spot: BadgeSpot
        /// The app named a control the first time it was asked at this size
        /// and answered every question: the spot is final.
        let sure: Bool
        /// Points along the title bar, as distances from the right edge, that
        /// any answer at this size named a control under. The badge keeps
        /// clear of all of them.
        let known: Set<Int>
        /// The last answer named a control the ones before it had not: the
        /// app is still filling in its tree.
        let grew: Bool
        /// The title bar was searched for controls. Not when the app has a
        /// distance of its own: only the height was measured.
        let probed: Bool
        /// The height came from the close button, not a fallback, so a
        /// retry at the same size need not look for it again.
        let topFound: Bool
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

        init(size: CGSize, spot: BadgeSpot, sure: Bool, known: Set<Int> = [], grew: Bool = false,
             probed: Bool = true, topFound: Bool = true, tries: Int, at now: TimeInterval) {
            self.size = size
            self.spot = spot
            self.sure = sure
            self.known = known
            self.grew = grew
            self.probed = probed
            self.topFound = topFound
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

    /// How many times a provisional answer is asked again before it is kept,
    /// about two seconds in all.
    nonisolated static let maxTries = 4
    /// The same for an app still filling in its tree when that runs out,
    /// about seven seconds in all.
    nonisolated static let maxTriesWhileGrowing = 6
    /// Remember this many windows; the least recently used is forgotten.
    nonisolated static let capacity = 32
    /// A resized window is measured once its size has held this long, so an
    /// animated resize (a window manager, zoom, tiling) is measured once at
    /// the end rather than at every step.
    nonisolated static let settle: TimeInterval = 0.2
    /// A window still changing size after this long is left until it stops,
    /// rather than kept under watch.
    nonisolated static let driftWatch: TimeInterval = 3
    /// The most time one measurement may spend asking an app, on the main thread.
    nonisolated static let budget: TimeInterval = 0.25

    private var cache: [UInt32: Entry] = [:]

    /// Distances set per app in Settings, by bundle identifier: see
    /// `BadgeOffsets`. An app with one is never searched.
    var offsets: [String: Double] = [:]
    private var bundleIDs: [pid_t: String] = [:]

    /// An app's bundle identifier, or "" if it has none.
    func bundleID(of pid: pid_t) -> String {
        if let known = bundleIDs[pid] { return known }
        // Not kept when missing: an app just launched may not say yet.
        guard let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return "" }
        if bundleIDs.count > 200 { bundleIDs.removeAll() }
        bundleIDs[pid] = id
        return id
    }

    /// Forget an app that quit, whose process number may be reused.
    func forget(pid: pid_t) { bundleIDs[pid] = nil }

    private func offset(for pid: pid_t) -> CGFloat? {
        guard !offsets.isEmpty else { return nil }
        return offsets[bundleID(of: pid)].map { CGFloat($0) }
    }

    /// The spot found, or measured height and the app's own distance.
    private func applying(_ offset: CGFloat?, to spot: BadgeSpot, width: CGFloat, side: CGFloat) -> BadgeSpot {
        guard let offset else { return spot }
        return BadgeSpot(right: BadgeOffsets.clamped(offset, width: width, side: side), top: spot.top)
    }

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
    nonisolated static func recheckDelay(afterTries tries: Int) -> TimeInterval {
        0.3 * pow(2, Double(max(tries - 1, 0)))
    }

    /// Whether to ask the app again, given what is known (already updated
    /// with the window's current size).
    ///
    /// While a mouse button is held, a window being resized keeps its last
    /// answer instead of being asked on every step of the drag.
    nonisolated static func shouldMeasure(_ entry: Entry?, now: TimeInterval, dragging: Bool) -> Bool {
        guard let entry else { return true }
        if dragging { return false }
        if entry.seenSize != entry.size { return now - entry.seenSince >= settle }
        if entry.sure || entry.tries >= triesAllowed(entry) { return false }
        return now - entry.measuredAt >= recheckDelay(afterTries: entry.tries)
    }

    nonisolated static func triesAllowed(_ entry: Entry) -> Int {
        entry.grew ? maxTriesWhileGrowing : maxTries
    }

    /// What a fresh answer adds to the earlier ones at the same size.
    ///
    /// An app that names a control the first time it is asked has its tree
    /// built already, and is believed at once. One that named nothing at
    /// first is still building it, and is never sure: it is asked until the
    /// tries run out.
    ///
    /// - Parameters:
    ///   - found: the points this answer named a control under.
    ///   - failed: the app did not answer every question.
    ///   - earlier: the points earlier answers at this size named, or nil if
    ///     this is the first try at it.
    nonisolated static func merge(found: Set<Int>, failed: Bool, earlier: Set<Int>?)
        -> (sure: Bool, known: Set<Int>, grew: Bool) {
        guard let earlier else { return (!failed && !found.isEmpty, found, false) }
        return (false, earlier.union(found), !found.isSubset(of: earlier))
    }

    /// Whether the answer will change by itself soon, so it is worth checking
    /// again shortly even if nothing else happens.
    nonisolated static func wantsRecheck(_ entry: Entry, now: TimeInterval) -> Bool {
        if let drift = entry.driftSince { return now - drift < driftWatch }
        return !entry.sure && entry.tries < triesAllowed(entry)
    }

    /// Clear `recheckWanted` before placing a round of badges.
    func beginPass() { recheckWanted = false }

    /// Where on the window to place the badge.
    func spot(pid: pid_t, windowID: UInt32, frame: NSRect, side: CGFloat) -> BadgeSpot {
        let now = ProcessInfo.processInfo.systemUptime
        let offset = offset(for: pid)
        var old = cache[windowID]
        // A distance set or removed since: the height still holds, but the
        // search is to be done, or no longer needed. No tries yet, so the
        // next answer counts as a first one.
        if let o = old, o.probed != (offset == nil) {
            old = Entry(size: o.size, spot: o.spot, sure: false, probed: offset == nil,
                        topFound: o.topFound, tries: 0, at: 0)
        }
        old?.see(frame.size, at: now)
        var entry: Entry
        if Self.shouldMeasure(old, now: now, dragging: NSEvent.pressedMouseButtons != 0) {
            let sameSize = old?.size == frame.size
            let earlier = sameSize && old!.tries > 0 ? old : nil
            let tries = (earlier?.tries ?? 0) + 1
            let knownTop = sameSize && old!.topFound ? old!.spot.top : nil
            let (spot, found, failed, topFound) = measure(pid: pid, windowID: windowID, frame: frame, side: side,
                                                          known: earlier?.known ?? [], top: knownTop,
                                                          probing: offset == nil, attempt: tries)
            if offset == nil {
                let merged = Self.merge(found: found, failed: failed, earlier: earlier?.known)
                entry = Entry(size: frame.size, spot: spot, sure: merged.sure, known: merged.known,
                              grew: merged.grew, topFound: topFound, tries: tries, at: now)
                let id = bundleID(of: pid)
                if !merged.known.isEmpty, !id.isEmpty {
                    BadgeOffsets.lastAutomatic[id] = Double(spot.right)
                }
            } else {
                // Only the height to find: done once it is found.
                entry = Entry(size: frame.size, spot: spot, sure: topFound, probed: false,
                              topFound: topFound, tries: tries, at: now)
            }
            if old == nil, cache.count >= Self.capacity,
               let oldest = cache.min(by: { $0.value.usedAt < $1.value.usedAt })?.key {
                cache[oldest] = nil
            }
        } else {
            entry = old!
        }
        cache[windowID] = entry
        if Self.wantsRecheck(entry, now: now) { recheckWanted = true }
        return applying(offset, to: entry.spot, width: frame.width, side: side)
    }

    /// The last answer for a window, without asking again.
    /// Counts as a use, so a pin showing its floating copy for hours keeps
    /// its answer while other windows come and go.
    func knownSpot(pid: pid_t, windowID: UInt32, side: CGFloat) -> (size: CGSize, spot: BadgeSpot)? {
        guard let entry = cache[windowID] else { return nil }
        cache[windowID]?.usedAt = ProcessInfo.processInfo.systemUptime
        return (entry.size, applying(offset(for: pid), to: entry.spot, width: entry.size.width, side: side))
    }

    /// Ask the app where the badge can go, keeping clear of `known` points
    /// too. Returns the points the app named a control under, and whether it
    /// failed to answer.
    ///
    /// - Parameters:
    ///   - top: the height found by an earlier try at the same size, which
    ///     cannot have changed, so it is not asked for again.
    ///   - probing: false to find only the height, for an app with a
    ///     distance of its own.
    private func measure(pid: pid_t, windowID: UInt32, frame: NSRect, side: CGFloat,
                         known: Set<Int>, top knownTop: CGFloat?, probing: Bool,
                         attempt: Int) -> (BadgeSpot, found: Set<Int>, failed: Bool, topFound: Bool) {
        guard let primary = NSScreen.screens.first else { return (.corner, [], true, false) }
        let app = AXUIElementCreateApplication(pid)
        // On the main thread: never wait long on a slow app.
        AXUIElementSetMessagingTimeout(app, 0.1)
        // Accessibility positions are top-left based, from the primary screen.
        let windowTop = primary.frame.height - frame.maxY

        // Line the badge up with the close button. Its middle is the line a
        // title bar's contents are centred on, however tall the bar is: a plain
        // title bar, a tall unified toolbar, a browser's tab strip.
        var top = knownTop ?? BadgeSpot.corner.top
        var topFound = knownTop != nil
        let deadline = ProcessInfo.processInfo.systemUptime + Self.budget
        if knownTop == nil,
           let window = WindowLevelManager.axWindow(pid: pid, windowID: windowID, timeout: 0.1),
           let mid = Self.closeButtonMidY(of: window) {
            top = BadgeSpot.top(centredOn: mid - windowTop, side: side)
            topFound = true
        }
        guard probing else {
            wplog("titlebar slot wid=\(windowID) pid=\(pid) try=\(attempt) top=\(Int(top)) found=\(topFound) distance set for the app")
            return (BadgeSpot(right: TitleBarSlot.margin, top: top), [], false, topFound)
        }
        let y = Float(windowTop + top + side / 2)
        var log: [String] = []
        var failed = false
        var found: Set<Int> = []
        var seen: Set<String> = []
        // Neighbouring points mostly land on the same element, or on children
        // of the same toolbar: what each element turned out to be is kept for
        // the rest of this measurement rather than asked again.
        var classified: [AXUIElement: (TitleBarSlot.Probe, String)] = [:]

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
                let (probe, role) = Self.classify(hit, memo: &classified)
                if probe == .taken {
                    log.append("\(Int(fromRight)):\(role)")
                    found.insert(Int(fromRight))
                    return .taken
                }
                seen.insert(role)
                return known.contains(Int(fromRight)) ? .taken : probe
            case .noValue, .attributeUnsupported:
                return known.contains(Int(fromRight)) ? .taken : .free
            default:
                log.append("\(Int(fromRight)):err\(err.rawValue)")
                failed = true
                return .failed
            }
        }
        wplog("titlebar slot wid=\(windowID) pid=\(pid) try=\(attempt) width=\(Int(frame.width)) top=\(Int(top)) inset=\(inset.map { "\(Int($0))" } ?? "default") failed=\(failed) known=\(known.sorted()) taken=[\(log.joined(separator: " "))] free=[\(seen.sorted().joined(separator: " "))]")
        return (BadgeSpot(right: inset ?? TitleBarSlot.margin, top: top), found, failed, topFound)
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
    ///
    /// Every element passed on the way is recorded in `memo` with the answer,
    /// and an element already there ends the walk.
    private static func classify(_ element: AXUIElement,
                                 memo: inout [AXUIElement: (TitleBarSlot.Probe, String)]) -> (TitleBarSlot.Probe, String) {
        var current: AXUIElement? = element
        var passed: [AXUIElement] = []
        var answer: (TitleBarSlot.Probe, String) = (.free, "")
        walk: for _ in 0..<5 {
            guard let el = current else { break }
            if let known = memo[el] {
                answer = known
                break
            }
            passed.append(el)
            // Elements an app hands back carry the default wait of several
            // seconds, not the app's.
            AXUIElementSetMessagingTimeout(el, 0.1)
            guard let role = string(el, kAXRoleAttribute) else { break }
            if controls.contains(role) { answer = (.taken, role); break walk }
            if surfaces.contains(role) { answer = (.free, role); break walk }
            var parent: AnyObject?
            guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parent) == .success else { break }
            current = WindowLevelManager.element(from: parent)
        }
        for el in passed { memo[el] = answer }
        return answer
    }

    private static func string(_ el: AXUIElement, _ attribute: String) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}

/// Where a badge sits on its window.
nonisolated struct BadgeSpot: Equatable {
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
