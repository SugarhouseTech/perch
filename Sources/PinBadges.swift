import AppKit

/// Small pin buttons in the top-right corner of windows' title bars.
///
/// - On every pinned window, a solid pin: click it to unpin. It follows the
///   floating pin while that is showing, and the real window while you are in
///   its app.
/// - On the window you are working in, a faint pin: click it to pin that window.
///
/// Each badge is Perch's own small window, ordered just above the window it
/// belongs to, so anything covering that window covers the badge too. The one
/// on the window in use sits a layer up, as nothing ordinary covers that
/// window. Both kinds can be turned off in Settings.
///
/// The app makes one, which lives as long as the app, so it never removes its
/// observers and has no deinit.
final class PinBadgeController {

    static let pinnedKey = "badgePinnedWindows"
    /// The focused window's button: see `updateFocusedBadge`.
    static let focusedLevel = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
    static let focusedKey = "badgeFocusedWindow"

    static var showsPinned: Bool { UserDefaults.standard.object(forKey: pinnedKey) as? Bool ?? true }
    static var showsFocused: Bool { UserDefaults.standard.object(forKey: focusedKey) as? Bool ?? true }

    private let tracker: PinnedWindowTracker
    /// Pin or unpin a window, with the same feedback as the shortcut.
    private let toggle: (ForeignWindow) -> Void

    private var pinnedBadges: [UInt32: BadgePanel] = [:]
    private let focusedBadge = BadgePanel(pinned: false)
    private var focusedWindow: ForeignWindow?
    /// Keeps badges off the window's own title-bar buttons.
    private let slots = TitleBarSlotFinder()
    /// Apps whose windows get a badge only once pinned: see `BadgeOffsets`.
    private var onlyWhenPinned: Set<String> = []

    // Nothing here runs on a timer while nothing is happening. A badge only
    // has to move when a window does, and every way a window can change says
    // so: the active app changes, the app reports a window focused, moved or
    // resized, a mouse button goes down (the start of every drag), the Space
    // changes, or a pin is made or removed. Each of those calls `refresh`,
    // which follows closely for a second and then stops. A click is the
    // exception, being by far the most common and usually nothing to do with
    // a window moving: it gets one check, and is followed only for as long as
    // the button stays down.
    //
    // This used to be one timer, ten times a second, for as long as Perch
    // was running, which kept an app that is idle nearly all day awake.

    /// Runs ten times a second, only for a moment after something changed and
    /// while a mouse button is held.
    private var followTimer: Timer?
    /// When to refresh, follow and stop: see `BadgeSchedule`.
    private var schedule = BadgeSchedule()
    /// Runs twice a second, only while something is pinned: a showing pin
    /// follows its window on a timer of its own, and its badge follows it.
    private var pinnedTimer: Timer?

    /// Accessibility notifications from the active app.
    private var appObserver: AXObserver?
    private var observedPID: pid_t = 0
    /// An app that would not take notifications is asked again only now and then.
    private var refusals = RefusalBackoff()
    // An app can report a moved or resized window dozens of times a second,
    // during an animation or a fight between window managers; a burst like
    // that is handled at the follow timer's pace instead of once per report
    // (see `BadgeSchedule.refresh`).

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(tracker: PinnedWindowTracker, toggle: @escaping (ForeignWindow) -> Void) {
        self.tracker = tracker
        self.toggle = toggle

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observe(workspace, name)
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification)
        workspace.observeOnMain(NSWorkspace.didTerminateApplicationNotification) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.slots.forget(pid: app.processIdentifier)
            }
        }
        // The two switches and the distances in Settings.
        observe(.default, UserDefaults.didChangeNotification)
        slots.offsets = BadgeOffsets.all()

        // Mouse buttons need no permission to watch, unlike keys. Clicks on
        // Perch's own windows are not reported here; a click on a badge
        // changes the pinned set, which refreshes by itself.
        _ = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp]
        ) { [weak self] _ in self?.refresh(following: false) }

        refresh()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        center.observeOnMain(name) { [weak self] _ in self?.refresh() }
    }

    // MARK: - Update

    /// Bring the badges up to date now, and follow closely for the next
    /// second: what was just reported is often the start of something still
    /// going on, such as a drag, an animated resize, or a pin fading in.
    ///
    /// - Parameter following: false for a mouse button going down or up, which
    ///   is followed only while the button is held. If the click did move a
    ///   window, the app says so, and that report is followed as usual.
    func refresh(following: Bool = true) {
        let decision = schedule.refresh(following: following, buttonHeld: NSEvent.pressedMouseButtons != 0, now: now)
        if decision.startsTimer { startFollowingTimer() }
        // A put-off refresh is part of a burst: the next follow tick picks it up.
        guard decision.runsNow else { return }
        slots.offsets = BadgeOffsets.all()
        onlyWhenPinned = BadgeOffsets.onlyWhenPinned()
        observeFrontmostApp()
        readFocusedWindow()
        update()

        let anyPinned = Self.showsPinned && !tracker.pinnedWindows.isEmpty
        if anyPinned, pinnedTimer == nil {
            let t = Timer.onMainUnscheduled(every: 0.5, repeats: true) { [weak self] in self?.update(restack: false) }
            t.tolerance = 0.1
            RunLoop.main.add(t, forMode: .common)
            pinnedTimer = t
        } else if !anyPinned {
            pinnedTimer?.invalidate()
            pinnedTimer = nil
        }
    }

    private func startFollowingTimer() {
        guard followTimer == nil else { return }
        // Common modes, so it keeps up during a drag.
        let t = Timer.onMainUnscheduled(every: BadgeSchedule.tickInterval, repeats: true) { [weak self] in self?.follow() }
        RunLoop.main.add(t, forMode: .common)
        followTimer = t
    }

    private func follow() {
        switch schedule.tick(now: now, buttonHeld: NSEvent.pressedMouseButtons != 0) {
        case .stop:
            followTimer?.invalidate()
            followTimer = nil
            return
        case .runPendingRefresh:
            observeFrontmostApp()
            readFocusedWindow()
        case .readFocusedWindow:
            // Asking the front app for its focused window is an Accessibility
            // call, so do it a few times a second rather than every tick.
            readFocusedWindow()
        case .update:
            break
        }
        update()
    }

    /// - Parameter restack: put each badge back above its window even if
    ///   nothing about it changed. Done after anything that may have raised a
    ///   window over it; the steady timer for pins only moves badges.
    private func update(restack: Bool = true) {
        slots.beginPass()
        updatePinnedBadges(restack: restack)
        updateFocusedBadge()
        // A window's app may not have described its title bar yet: keep
        // checking until it has, or the finder gives up on it.
        if slots.recheckWanted {
            if schedule.recheckWanted(now: now) { startFollowingTimer() }
        }
    }

    private func readFocusedWindow() {
        guard Self.showsFocused else { focusedWindow = nil; return }
        switch Self.focusedForeignWindow() {
        case .window(let window):
            focusedWindow = window
        case .noWindow:
            focusedWindow = nil
        case .noAnswer(let pid, let error):
            // A busy app can miss the short wait: Discord does while starting
            // up. Hiding the badge then would also end the checks still
            // waiting on its title bar. Keep the last answer for the same app;
            // a window it has closed since drops out when its frame is looked up.
            if error == AXError.cannotComplete.rawValue {
                wplog("badge: focused window of pid=\(pid) not answered (err \(error)), keeping last")
            } else {
                wplog("badge: focused window of pid=\(pid) failed (err \(error)), keeping last")
            }
            focusedWindow = BadgePlacement.focusedAfterNoAnswer(
                last: focusedWindow, lastPID: \.ownerPID, answeringPID: pid)
        }
    }

    // MARK: - The active app's window changes

    /// Ask the active app to report when its focused window changes and when
    /// a window moves, is resized or is minimised. Registered on the app, the
    /// notifications cover all its windows. This is what catches a change
    /// made from the keyboard, where no mouse button goes down.
    private func observeFrontmostApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        guard pid != observedPID else { return }
        stopObservingApp()
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        let now = self.now
        guard refusals.mayAsk(pid: pid, now: now) else { return }

        var created: AXObserver?
        guard AXObserverCreate(pid, badgeAXCallback, &created) == .success, let observer = created else { return }
        let element = AXUIElementCreateApplication(pid)
        // Registering waits on the app, on the main thread: never long.
        AXUIElementSetMessagingTimeout(element, 0.1)
        let context = Unmanaged.passUnretained(self).toOpaque()
        var registered = false
        for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                     kAXWindowMovedNotification, kAXWindowResizedNotification,
                     kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            if AXObserverAddNotification(observer, element, name as CFString, context) == .success {
                registered = true
            }
        }
        // Nothing registered: no Accessibility yet, or the app is not
        // answering. Leave it unrecorded so a later refresh tries again, but
        // not for a few seconds: each try waits on the app.
        guard registered else {
            if refusals.refused(pid: pid, now: now) {
                DispatchQueue.main.asyncAfter(deadline: .now() + RefusalBackoff.retryDelay) { [weak self] in
                    guard let self, self.observedPID == 0,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                    self.refresh(following: false)
                }
            }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        appObserver = observer
        observedPID = pid
    }

    private func stopObservingApp() {
        if let appObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(appObserver), .commonModes)
        }
        appObserver = nil
        observedPID = 0
    }

    private func updatePinnedBadges(restack: Bool) {
        let pinned = Self.showsPinned ? tracker.pinnedWindows : []
        let ids = Set(pinned.map(\.windowID))
        for (id, badge) in pinnedBadges where !ids.contains(id) {
            badge.orderOut(nil)
            pinnedBadges[id] = nil
        }
        for pw in pinned {
            let badge = pinnedBadges[pw.windowID] ?? {
                let b = BadgePanel(pinned: true)
                pinnedBadges[pw.windowID] = b
                return b
            }()
            badge.onClick = { [weak self] in
                self?.toggle(ForeignWindow(windowID: pw.windowID, ownerPID: pw.ownerPID,
                                           ownerName: pw.ownerName, windowTitle: pw.windowTitle))
            }
            // While the floating pin is showing it is what you see, and it may be
            // cropped or moved away from the real window, so the badge goes on it.
            if let overlay = tracker.overlay(for: pw.windowID), overlay.isPinVisible, overlay.isVisible {
                // A pin cropped down to a sliver would be mostly badge, and the
                // badge would take the clicks meant to move it or clear its
                // crop. Such a pin is unpinned from the menu instead.
                if overlay.frame.width >= BadgePanel.side * 3, overlay.frame.height >= BadgePanel.side * 2 {
                    badge.show(on: overlay.frame, at: overlaySpot(pw.windowID, overlay),
                               level: overlay.level, above: overlay.windowNumber, restack: restack)
                } else {
                    badge.orderOut(nil)
                }
            } else if let frame = Self.onScreenFrame(of: pw.windowID) {
                let spot = slots.spot(pid: pw.ownerPID, windowID: pw.windowID, frame: frame, side: BadgePanel.side)
                badge.show(on: frame, at: spot, level: .normal, above: Int(pw.windowID), restack: restack)
            } else {
                badge.orderOut(nil)
            }
        }
    }

    private func updateFocusedBadge() {
        guard let fw = focusedWindow, !tracker.isPinned(windowID: fw.windowID),
              onlyWhenPinned.isEmpty || !onlyWhenPinned.contains(slots.bundleID(of: fw.ownerPID)),
              let frame = Self.onScreenFrame(of: fw.windowID),
              frame.width >= 200, frame.height >= 120,
              // A window filling a whole display is full screen: a film, a
              // presentation, a game. There is no title bar for the badge to
              // sit in there, only the corner of the content.
              !NSScreen.screens.contains(where: { $0.frame == frame }) else {
            if focusedBadge.isVisible {
                wplog("badge: hiding focused button (\(focusedWindow.map { "wid=\($0.windowID)" } ?? "no focused window"))")
            }
            focusedBadge.orderOut(nil)
            return
        }
        focusedBadge.onClick = { [weak self] in
            // Full details (title and all) for the menu; the badge's own copy is minimal.
            let full = WindowDetector.getFrontmostForeignWindow()
            self?.toggle(full?.windowID == fw.windowID ? full! : fw)
        }
        let spot = slots.spot(pid: fw.ownerPID, windowID: fw.windowID, frame: frame, side: BadgePanel.side)
        // One layer above ordinary windows. A click on a window raises it to
        // the top of the ordinary layer, above this button, which is another
        // app's window, until the click's refresh puts the button back: it
        // blinked on every click (measured at 4-9 ms, on mouse up). The window
        // in use is already the front ordinary window, so a layer up covers
        // nothing that should be in front of the button.
        focusedBadge.show(on: frame, at: spot, level: Self.focusedLevel, above: Int(fw.windowID))
    }

    /// The floating pin shows the window scaled to its own size, so a spot
    /// found on the window scales with it. A cropped pin shows only part of the
    /// window and its corner is somewhere else entirely, so it keeps the corner.
    private func overlaySpot(_ windowID: UInt32, _ overlay: WindowOverlay) -> BadgeSpot {
        guard overlay.crop == nil,
              let known = slots.knownSpot(pid: overlay.targetPID, windowID: windowID, side: BadgePanel.side),
              known.size.width > 0 else { return .corner }
        return BadgePlacement.scaledSpot(known.spot, windowWidth: known.size.width,
                                         overlayWidth: overlay.frame.width, side: BadgePanel.side)
    }

    // MARK: - Windows

    /// The focused window of the frontmost app, if it is an ordinary window of
    /// another app.
    private enum FocusedLookup {
        case window(ForeignWindow)
        /// No ordinary window of another app has focus.
        case noWindow
        /// The app did not answer: it was busy, or failed the question.
        case noAnswer(pid_t, Int32)
    }

    private static func focusedForeignWindow() -> FocusedLookup {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return .noWindow }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Several times a second, on the main thread: never wait long on a slow app.
        AXUIElementSetMessagingTimeout(axApp, 0.1)
        var ref: AnyObject?
        let err = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref)
        // Any failure counts as no answer, not as no window. An app handling
        // a click, above all one with web views inside its window, can fail
        // the question for a moment, and treating that as "no window" hid the
        // button until the button came up again: it blinked on every click.
        // A window that really has gone drops out when its frame is looked up.
        guard err == .success else { return .noAnswer(app.processIdentifier, err.rawValue) }
        guard let window = WindowLevelManager.element(from: ref) else { return .noWindow }
        let wid = WindowLevelManager.windowID(of: window)
        WindowSurvey.record(window, windowID: wid, app: app)
        guard let wid else { return .noWindow }
        return .window(ForeignWindow(windowID: wid, ownerPID: app.processIdentifier,
                                     ownerName: app.localizedName ?? "", windowTitle: ""))
    }

    /// A window's frame in AppKit coordinates, if it is an ordinary on-screen window.
    private static func onScreenFrame(of windowID: UInt32) -> NSRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID))
                          as? [[String: Any]])?.first,
              info[kCGWindowIsOnscreen as String] as? Bool == true,
              info[kCGWindowLayer as String] as? Int == 0,
              let b = info[kCGWindowBounds as String] as? [String: CGFloat],
              let primary = NSScreen.screens.first else { return nil }
        let h = b["Height"] ?? 0
        // Window-list bounds are top-left based; AppKit's are bottom-left from the primary screen.
        return NSRect(x: b["X"] ?? 0, y: primary.frame.height - (b["Y"] ?? 0) - h,
                      width: b["Width"] ?? 0, height: h)
    }
}

/// Accessibility notifications arrive at a C function, on the main run loop
/// (its source is added to the main run loop where the observer is made).
nonisolated private func badgeAXCallback(_ observer: AXObserver, _ element: AXUIElement,
                                         _ notification: CFString, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let controller = Unmanaged<PinBadgeController>.fromOpaque(context)
    MainActor.assumeIsolated { controller.takeUnretainedValue().refresh() }
}

// MARK: - Badge window

private final class BadgePanel: NSPanel {

    static let side: CGFloat = 22
    var onClick: (() -> Void)?

    init(pinned: Bool) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.side, height: Self.side),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = pinned
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        contentView = BadgeView(pinned: pinned) { [weak self] in self?.onClick?() }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The window this badge was last put above.
    private var orderedAbove = 0

    /// Put the badge at `spot` on `frame`, just above window `above`.
    ///
    /// - Parameter restack: order it above the window even if it already was.
    func show(on frame: NSRect, at spot: BadgeSpot, level: NSWindow.Level, above windowNumber: Int,
              restack: Bool = true) {
        let origin = NSPoint(x: frame.maxX - Self.side - spot.right,
                             y: frame.maxY - Self.side - spot.top)
        let moved = self.frame.origin != origin || self.level != level
        if self.frame.origin != origin { setFrameOrigin(origin) }
        if self.level != level { self.level = level }
        guard restack || moved || !isVisible || orderedAbove != windowNumber else { return }
        orderedAbove = windowNumber
        order(.above, relativeTo: windowNumber)
    }
}

private final class BadgeView: NSView {

    private let pinned: Bool
    private let action: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }

    init(pinned: Bool, action: @escaping () -> Void) {
        self.pinned = pinned
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: BadgePanel.side, height: BadgePanel.side))
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        toolTip = pinned ? "Unperch this window" : "Perch this window on top"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // The click must work while another app is active, without activating Perch.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { action() }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        let fill: NSColor = pinned
            ? .systemOrange
            : NSColor.gray.withAlphaComponent(hovering ? 0.85 : 0.35)
        fill.setFill()
        circle.fill()

        let name = pinned || hovering ? "pin.fill" : "pin"
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let s = symbol.size
        symbol.draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2,
                               width: s.width, height: s.height))
    }
}
