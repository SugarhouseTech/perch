import Foundation

/// The decisions `PinnedWindowTracker` makes, as pure functions. The tracker
/// gathers the inputs from AppKit and Core Graphics and applies the answers;
/// nothing here touches a window, a timer or the clock.

/// A change to a pin's layer.
nonisolated enum PinLayerChange: Equatable {
    case sendBehind
    case bringToFront
}

/// What a pin does when another app becomes active.
nonisolated enum ActivationAction: Equatable {
    /// A cropped pin's own window may or may not be the one in use, so the
    /// activated app alone does not settle it. See `PinPolicy.layeringChange`.
    case decideByLayering
    case change(PinLayerChange)
}

nonisolated enum PinPolicy {

    // MARK: - Pruning closed windows

    /// What a pruning pass decided.
    struct PruneOutcome: Equatable {
        /// Pins to take down.
        var remove: Set<UInt32>
        /// Pins whose last lookup said they are gone. One more such lookup
        /// removes them.
        var missingOnce: Set<UInt32>
    }

    /// Whether the window lookups can be trusted enough to act on at all.
    /// Callers check this before looking anything up, so no lookups are made
    /// while it is false.
    ///
    /// - Not before `quietUntil`: the window list is unreliable for a while
    ///   after wake or a display change, longer than two lookups.
    /// - Not while another user has the screen: this session's windows are
    ///   not ours to judge until it comes back.
    static func mayPrune(now: TimeInterval, quietUntil: TimeInterval, onConsole: Bool) -> Bool {
        now >= quietUntil && onConsole
    }

    /// A window is unpinned only when two lookups in a row say it is gone.
    /// The window list can come back empty or short while the displays
    /// change, around sleep, or while another user has the screen, and that
    /// once unpinned everything.
    ///
    /// `lookups` maps a window ID to whether it exists: true, false, or nil
    /// when the lookup failed. A failed lookup, or an ID with no entry, says
    /// nothing either way, so it ends a streak of "gone" answers. So does a
    /// pass that is gated off: a window missing from one list before sleep
    /// and one after waking has not been seen gone twice in a row, only
    /// twice either side of a time the lists cannot be trusted.
    static func prune(pinned: Set<UInt32>,
                      lookups: [UInt32: Bool?],
                      missingOnce: Set<UInt32>,
                      now: TimeInterval,
                      quietUntil: TimeInterval,
                      onConsole: Bool) -> PruneOutcome {
        guard mayPrune(now: now, quietUntil: quietUntil, onConsole: onConsole) else {
            return PruneOutcome(remove: [], missingOnce: [])
        }
        let gone = pinned.filter { (lookups[$0] ?? nil) == false }
        return PruneOutcome(remove: gone.intersection(missingOnce), missingOnce: gone)
    }

    // MARK: - Layering

    /// What a pin does when `activatedPID` becomes the active app.
    /// - cropped: decided by layering, window by window
    /// - the activated app owns the window: send behind, the user is using
    ///   the real window
    /// - otherwise: bring to front, the user switched away and the pinned
    ///   content should stay visible
    static func activationAction(isCropped: Bool, ownerPID: pid_t, activatedPID: pid_t) -> ActivationAction {
        if isCropped { return .decideByLayering }
        return .change(ownerPID == activatedPID ? .sendBehind : .bringToFront)
    }

    /// Act only on a change: this runs twice a second for cropped pins, and
    /// bringToFront logs each call it skips.
    static func layeringChange(inUse: Bool, visible: Bool) -> PinLayerChange? {
        if inUse, visible { return .sendBehind }
        if !inUse, !visible { return .bringToFront }
        return nil
    }

    /// Whether the layering timer should run: some cropped pin whose app is
    /// in front. With any other app in front the answer cannot change until
    /// the next app switch, which updates it anyway.
    static func layeringTimerNeeded(pins: [(isCropped: Bool, targetPID: pid_t)],
                                    frontPID: pid_t?) -> Bool {
        pins.contains { $0.isCropped && $0.targetPID == frontPID }
    }

    // MARK: - The menu's list of pins

    /// The order pins are listed in the menu: the front app's first, since
    /// that is most likely the one being thought about, then by name.
    static func menuOrder(_ pinned: some Collection<PinnedWindow>, frontPID: pid_t?) -> [PinnedWindow] {
        pinned.sorted { a, b in
            let aFront = a.ownerPID == frontPID, bFront = b.ownerPID == frontPID
            if aFront != bFront { return aFront }
            let byName = a.displayLabel.localizedStandardCompare(b.displayLabel)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.windowID < b.windowID  // a stable order for equal names
        }
    }
}
