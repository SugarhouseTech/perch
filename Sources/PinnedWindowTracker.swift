import AppKit

nonisolated struct PinnedWindow: Hashable {
    let windowID: UInt32
    let ownerPID: pid_t
    let ownerName: String
    let windowTitle: String

    /// Display label for the menu: "Safari — GitHub" or "Terminal" if no title.
    var displayLabel: String {
        if windowTitle.isEmpty {
            return ownerName
        }
        let maxLen = 40
        let title = windowTitle.count > maxLen
            ? String(windowTitle.prefix(maxLen)) + "…"
            : windowTitle
        return "\(ownerName) — \(title)"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
    }

    static func == (lhs: PinnedWindow, rhs: PinnedWindow) -> Bool {
        lhs.windowID == rhs.windowID
    }
}

/// The app's one tracker. It lives as long as the app, so it never removes its
/// observers and has no deinit.
final class PinnedWindowTracker {

    private(set) var pinnedWindows: Set<PinnedWindow> = []
    private var overlays: [UInt32: WindowOverlay] = [:]
    private var pollTimer: Timer?
    /// Runs only while a pin is cropped. See `updateCroppedLayering`.
    private var layeringTimer: Timer?

    /// Called whenever the pinned set changes.
    var onChange: (() -> Void)?
    /// Called when a pin was taken down because Screen Recording was refused
    /// after the pin was made, so the user can be told why it went.
    var onCaptureDenied: ((PinnedWindow) -> Void)?
    /// Called when a pin was refused because Screen Recording is not granted.
    var onNeedsScreenRecording: (() -> Void)?

    init() {
        observeAppActivation()
        observeAppTermination()
        observeWakeAndDisplays()
    }

    // MARK: - Public API



    func overlay(for windowID: UInt32) -> WindowOverlay? { overlays[windowID] }

    func isPinned(windowID: UInt32) -> Bool {
        pinnedWindows.contains(where: { $0.windowID == windowID })
    }

    func pin(window: ForeignWindow) {
        let pw = PinnedWindow(
            windowID: window.windowID,
            ownerPID: window.ownerPID,
            ownerName: window.ownerName,
            windowTitle: window.windowTitle
        )
        guard !pinnedWindows.contains(pw) else { return }
        guard hasScreenRecording() else { return }

        pinnedWindows.insert(pw)

        let overlay = WindowOverlay(
            windowID: CGWindowID(window.windowID),
            pid: window.ownerPID
        )
        overlay.onCropChange = { [weak self] in self?.cropsChanged() }
        overlay.onCaptureDenied = { [weak self] in
            wplog("pin: capture refused, unpinning wid=\(pw.windowID)")
            self?.unpin(windowID: pw.windowID, bringForward: false)
            self?.onCaptureDenied?(pw)
        }
        overlays[window.windowID] = overlay
        wplog("pin: overlay created for wid=\(window.windowID)")

        // A pin normally starts out of sight, because its window is the one
        // in use, and comes up when the user switches to another app. Pinned
        // from the menu while its app is not the active one, there is no
        // switch coming to bring it up, so it comes up now.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != window.ownerPID {
            overlay.bringToFront()
        } else {
            overlay.prepareBehind()
        }

        pinsChanged()
    }

    /// Whether Screen Recording is granted. If not, the owner is told, and
    /// shows the setup window, which asks for it and says why.
    ///
    /// This used to ask for itself: the system's prompt the first time, and
    /// System Settings thrown open on every refused pin after that, from a
    /// shortcut that works in any app.
    private func hasScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        wplog("pin: Screen Recording not granted")
        onNeedsScreenRecording?()
        return false
    }

    /// - Parameter bringForward: bring the window to the front and give it
    ///   the keyboard. True when the user unpins: they are done with the
    ///   window floating, not with the window, and usually want to use it
    ///   next. Without this, unpinning while in another app made the window
    ///   vanish behind that app. False when the app unpins by itself (capture
    ///   refused), which must not move focus.
    func unpin(windowID: UInt32, bringForward: Bool) {
        guard let pw = pinnedWindows.first(where: { $0.windowID == windowID }) else { return }
        if bringForward { overlays[windowID]?.activateRealWindow() }
        overlays[windowID]?.hideOverlay()
        overlays[windowID] = nil
        pinnedWindows.remove(pw)
        pinsChanged()
    }

    func unpinAll() {
        for (_, overlay) in overlays {
            overlay.hideOverlay()
        }
        overlays.removeAll()
        pinnedWindows.removeAll()
        pinsChanged()
    }

    func updateCaptureRate() {
        for (_, overlay) in overlays {
            overlay.applyCaptureRate()
        }
    }

    func updateAllSpaces() {
        for (_, overlay) in overlays {
            overlay.updateCollectionBehavior()
        }
    }

    func toggle(window: ForeignWindow) {
        if isPinned(windowID: window.windowID) {
            unpin(windowID: window.windowID, bringForward: true)
        } else {
            pin(window: window)
        }
    }

    // MARK: - App activation observer

    private func observeAppActivation() {
        NSWorkspace.shared.notificationCenter.observeOnMain(NSWorkspace.didActivateApplicationNotification) { [weak self] notification in
            guard let self = self, !self.pinnedWindows.isEmpty else { return }

            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let activatedPID = app.processIdentifier
            let myPID = ProcessInfo.processInfo.processIdentifier
            guard activatedPID != myPID else { return }

            // For each pinned window:
            // - If the activated app owns this window → drop overlay behind (user is using real window)
            // - Otherwise → raise overlay to front (user switched away, keep pinned content visible)
            for pw in self.pinnedWindows {
                if let overlay = self.overlays[pw.windowID] {
                    switch PinPolicy.activationAction(isCropped: overlay.isCropped,
                                                      ownerPID: pw.ownerPID,
                                                      activatedPID: activatedPID) {
                    case .decideByLayering: self.updateLayering(of: overlay)
                    case .change(let change): self.apply(change, to: overlay)
                    }
                    // A pin that stayed up through this switch but has lost
                    // its stream gets it back here.
                    overlay.reviveStreamIfNeeded()
                }
            }
            self.cropsChanged()
        }
    }

    // MARK: - Sleep and display changes

    /// Sleep and a change of displays can each end a pin's stream. The stream
    /// restarts itself a few times and then gives up, which a long sleep
    /// outlasts, leaving the pin on a frozen frame.
    private func observeWakeAndDisplays() {
        let revive: @MainActor (Notification) -> Void = { [weak self] _ in
            self?.pruneQuietUntil = ProcessInfo.processInfo.systemUptime + 10
            // A moment for the displays to settle; a stream started at once
            // is as likely to be stopped again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self?.overlays.values.forEach { $0.reviveStreamIfNeeded(force: true) }
            }
        }
        NSWorkspace.shared.notificationCenter.observeOnMain(NSWorkspace.screensDidWakeNotification, revive)
        NotificationCenter.default.observeOnMain(NSApplication.didChangeScreenParametersNotification, revive)
    }

    // MARK: - Cropped pins

    /// A cropped pin goes behind only while its own window is the one in use,
    /// not whenever its app is active (see `WindowOverlay.isTargetInUse`).
    /// Switching windows inside one app raises no notification, so while a
    /// cropped pin's app is in front its layering is checked on a timer. Half
    /// a second matches how often a visible pin already follows its window.
    /// With any other app in front the answer cannot change until the next
    /// app switch, which updates it anyway, so the timer runs only then.
    private static let layeringInterval: TimeInterval = 0.5

    private func cropsChanged() {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let needed = PinPolicy.layeringTimerNeeded(
            pins: overlays.values.map { (isCropped: $0.isCropped, targetPID: $0.targetPID) },
            frontPID: frontPID)
        if needed, layeringTimer == nil {
            layeringTimer = Timer.onMain(every: Self.layeringInterval, repeats: true) { [weak self] in
                self?.updateCroppedLayering()
            }
            layeringTimer?.tolerance = 0.1
        } else if !needed {
            layeringTimer?.invalidate()
            layeringTimer = nil
        }
    }

    private func updateCroppedLayering() {
        // The last cropped pin may have been unpinned or closed since.
        guard overlays.values.contains(where: { $0.isCropped }) else {
            cropsChanged()
            return
        }
        // WindowPin itself in front (its menu or settings) changes nothing,
        // as with app activation.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                != ProcessInfo.processInfo.processIdentifier else { return }
        for overlay in overlays.values where overlay.isCropped {
            updateLayering(of: overlay)
        }
    }

    private func updateLayering(of overlay: WindowOverlay) {
        guard let change = PinPolicy.layeringChange(inUse: overlay.isTargetInUse,
                                                    visible: overlay.isPinVisible) else { return }
        apply(change, to: overlay)
    }

    private func apply(_ change: PinLayerChange, to overlay: WindowOverlay) {
        switch change {
        case .sendBehind: overlay.sendBehind()
        case .bringToFront: overlay.bringToFront()
        }
    }

    // MARK: - Polling for closed windows

    /// Tell the owner the pinned set changed, and look for closed windows only
    /// while there are pins to lose. With nothing pinned WindowPin has no
    /// timer running at all.
    private func pinsChanged() {
        if pinnedWindows.isEmpty {
            pollTimer?.invalidate()
            pollTimer = nil
        } else if pollTimer == nil {
            pollTimer = Timer.onMain(every: 2.0, repeats: true) { [weak self] in
                self?.pruneClosedWindows()
            }
            // Lets macOS fire it together with other timers.
            pollTimer?.tolerance = 0.5
        }
        onChange?()
    }

    /// Pinned windows missing from the last window list. A window goes only
    /// when two lists in a row lack it: the list can come back empty or short
    /// while the displays change, around sleep, or while another user has the
    /// screen, and that once unpinned everything.
    private var missingOnce: Set<UInt32> = []

    /// No pruning until then: the window list is unreliable for a while
    /// after wake, longer than two lookups.
    private var pruneQuietUntil: TimeInterval = 0

    private func pruneClosedWindows() {
        guard !pinnedWindows.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Unknown counts as on the console: only a definite "no" holds back.
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let onConsole = session?[kCGSessionOnConsoleKey as String] as? Bool != false
        // Skip the lookups too while they would be ignored, and start the
        // count again afterwards (see `PinPolicy.prune`).
        guard PinPolicy.mayPrune(now: now, quietUntil: pruneQuietUntil, onConsole: onConsole) else {
            missingOnce = []
            return
        }
        // One small lookup per pin rather than a listing of every window on
        // the system.
        var lookups: [UInt32: Bool?] = [:]
        for pw in pinnedWindows { lookups[pw.windowID] = WindowDetector.windowExists(pw.windowID) }
        let outcome = PinPolicy.prune(pinned: Set(pinnedWindows.map(\.windowID)),
                                      lookups: lookups,
                                      missingOnce: missingOnce,
                                      now: now,
                                      quietUntil: pruneQuietUntil,
                                      onConsole: onConsole)
        missingOnce = outcome.missingOnce
        let removed = pinnedWindows.filter { outcome.remove.contains($0.windowID) }
        guard !removed.isEmpty else { return }
        for pw in removed {
            overlays[pw.windowID]?.hideOverlay()
            overlays[pw.windowID] = nil
            pinnedWindows.remove(pw)
        }
        pinsChanged()
    }

    // MARK: - App termination

    private func observeAppTermination() {
        NSWorkspace.shared.notificationCenter.observeOnMain(NSWorkspace.didTerminateApplicationNotification) { [weak self] notification in
            guard let self = self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            let removed = self.pinnedWindows.filter { $0.ownerPID == pid }
            guard !removed.isEmpty else { return }
            for pw in removed {
                self.overlays[pw.windowID]?.hideOverlay()
                self.overlays[pw.windowID] = nil
                self.pinnedWindows.remove(pw)
            }
            self.pinsChanged()
        }
    }
}
