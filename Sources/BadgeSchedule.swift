import Foundation

// The timing decisions behind `PinBadgeController`, kept apart from its timers
// and Accessibility calls so they can be tested with time passed in. Each
// type here only answers "should this run now?"; the controller does the work.

/// When the badges refresh and how long they are followed afterwards.
///
/// The controller owns one timer that fires every `tickInterval` while this
/// says it should run. Nothing runs by itself: with no events, `isFollowing`
/// stays false and no refresh is ever due.
struct BadgeSchedule {

    /// Refreshes closer together than this are one burst.
    static let burstGap: TimeInterval = 0.05
    /// How long a refresh that follows keeps the timer going.
    static let followAfterRefresh: TimeInterval = 1
    /// How long a put-off refresh keeps it going: just enough to be picked up.
    static let followAfterPutOff: TimeInterval = 0.2
    /// How long to keep going while a title bar is still being worked out.
    static let followAfterRecheck: TimeInterval = 0.5
    static let tickInterval: TimeInterval = 0.1
    /// The focused window is read on every this-many-th tick.
    static let focusReadEvery = 3

    /// When the last refresh ran, whether one was put off since, and until
    /// when the timer is wanted regardless of the mouse.
    private(set) var lastRefresh: TimeInterval = -.infinity
    private(set) var refreshPending = false
    private(set) var followUntil: TimeInterval = -.infinity
    /// Whether the controller has a timer running.
    private(set) var isFollowing = false
    private var ticks = 0

    struct Refresh: Equatable {
        /// Do the whole refresh now. False: it was put off for the next tick.
        var runsNow: Bool
        /// The controller should create its timer.
        var startsTimer: Bool
    }

    /// Something reported a change.
    ///
    /// An app can report a moved window dozens of times a second, so a refresh
    /// within `burstGap` of the last is put off and picked up by the timer.
    ///
    /// - Parameters:
    ///   - following: false for a mouse button going down or up, which is
    ///     followed only while the button is held.
    ///   - buttonHeld: a mouse button is down right now.
    mutating func refresh(following: Bool, buttonHeld: Bool, now: TimeInterval) -> Refresh {
        if following { extend(to: now + Self.followAfterRefresh) }
        if now - lastRefresh < Self.burstGap {
            refreshPending = true
            extend(to: now + Self.followAfterPutOff)
            return Refresh(runsNow: false, startsTimer: startFollowing())
        }
        lastRefresh = now
        refreshPending = false
        return Refresh(runsNow: true, startsTimer: (following || buttonHeld) ? startFollowing() : false)
    }

    /// A title bar is still being worked out: keep checking a little longer.
    /// Returns whether the controller should create its timer.
    mutating func recheckWanted(now: TimeInterval) -> Bool {
        extend(to: now + Self.followAfterRecheck)
        return startFollowing()
    }

    enum Tick: Equatable {
        /// Nothing left to follow: the controller drops its timer.
        case stop
        /// A refresh was put off: do it now, then update.
        case runPendingRefresh
        /// Read the focused window, then update.
        case readFocusedWindow
        /// Just update.
        case update
    }

    mutating func tick(now: TimeInterval, buttonHeld: Bool) -> Tick {
        guard now < followUntil || buttonHeld else {
            isFollowing = false
            return .stop
        }
        ticks += 1
        if refreshPending {
            refreshPending = false
            lastRefresh = now
            return .runPendingRefresh
        }
        return ticks % Self.focusReadEvery == 0 ? .readFocusedWindow : .update
    }

    private mutating func extend(to time: TimeInterval) { followUntil = max(followUntil, time) }

    private mutating func startFollowing() -> Bool {
        guard !isFollowing else { return false }
        isFollowing = true
        ticks = 0
        return true
    }
}

/// How often an app that refuses Accessibility notifications is asked again.
/// Asking a hung app waits on it, on the main thread.
struct RefusalBackoff {

    /// A second the first time, as an app just launched often answers a
    /// moment later; five after that.
    static let firstWait: TimeInterval = 1
    static let laterWait: TimeInterval = 5
    /// The one scheduled retry, just after `firstWait`.
    static let retryDelay: TimeInterval = 1.05

    private var pid: Int32 = 0
    private var askedAt: TimeInterval = 0
    private var wait: TimeInterval = firstWait

    func mayAsk(pid: Int32, now: TimeInterval) -> Bool {
        pid != self.pid || now - askedAt >= wait
    }

    /// The app refused. Returns whether to schedule one retry, so a launching
    /// app is not left unobserved until the next click; a hung one waits for those.
    mutating func refused(pid: Int32, now: TimeInterval) -> Bool {
        let first = pid != self.pid
        self.pid = pid
        askedAt = now
        wait = first ? Self.firstWait : Self.laterWait
        return first
    }
}

enum BadgePlacement {

    /// The floating pin shows the window scaled to its own size, so a spot
    /// found on the window scales with it, and stays clear of both edges.
    static func scaledSpot(_ spot: BadgeSpot, windowWidth: CGFloat, overlayWidth: CGFloat,
                           side: CGFloat) -> BadgeSpot {
        var scaled = spot.scaled(by: overlayWidth / windowWidth)
        scaled.right = min(max(scaled.right, TitleBarSlot.margin), overlayWidth - side * 2)
        scaled.top = max(scaled.top, 0)
        return scaled
    }

    /// What to do with the focused window when its app did not answer in time.
    /// A busy app can miss the short wait, and hiding the badge then would also
    /// end the checks still waiting on its title bar, so the last window is
    /// kept, but only for the same app.
    static func focusedAfterNoAnswer<W>(last: W?, lastPID: (W) -> Int32, answeringPID: Int32) -> W? {
        guard let last, lastPID(last) == answeringPID else { return nil }
        return last
    }
}
