import Foundation

/// When a pin's capture stream runs, and what to do when it will not.
///
/// A pin films its window only while it can be seen. It comes up when the
/// user switches away from the window's app and goes behind when they switch
/// back, keeping its stream for a few seconds in case they return at once. It
/// pauses while out of sight (another Space, a full-screen app, a sleeping
/// display). A stream that fails is retried a few times, a second apart, and
/// then left until something gives it a fresh start.
///
/// Everything that happens to a pin arrives here as an `Event`, including the
/// late answers of ScreenCaptureKit and of the pin's own timers, and comes
/// back as `Effect`s for `WindowOverlay` to carry out. Nothing here touches a
/// stream or a timer, so the rules can be tested over any order of events.
struct StreamLifecycle {

    /// Retries of a failed stream or of a window lookup, between fresh starts.
    static let maxRestarts = 5
    /// How long after a failure to try again.
    static let retryDelay: TimeInterval = 1
    /// How long a stream outlives its pin going behind. Switching to the
    /// pinned app and straight back is common (a glance, a Cmd-Tab too far),
    /// and a stream kept for a few seconds is reused instead of rebuilt.
    static let behindGrace: TimeInterval = 3
    /// How often a revive that was not asked for by a wake or a display
    /// change may start a stream. A pin whose stream will not start would
    /// else get a fresh set of retries, each a full listing of every window,
    /// at every app switch.
    static let reviveInterval: TimeInterval = 30

    enum Event: Equatable {
        /// The pin was made: look its window up, ready for later.
        case created
        /// The pin was made visible. `onScreen`: it has been shown before, so
        /// it only has to be raised; otherwise it is shown for the first time
        /// and reports `.fadedIn` once it is.
        case broughtToFront(onScreen: Bool)
        /// Shown for the first time, after its first screenshot.
        case fadedIn
        case sentBehind
        /// The grace after going behind is over.
        case behindGraceElapsed
        /// The system says whether the pin can be seen at all.
        case occlusion(hidden: Bool)
        /// Start the stream again if the pin is showing without one. `force`
        /// for a wake or a display change, which really can end a stream.
        /// `onScreen` and `hidden` are asked afresh rather than trusted.
        case revive(force: Bool, now: TimeInterval, onScreen: Bool, hidden: Bool)
        /// The lookup of the window in ScreenCaptureKit's list finished.
        case resolved(found: Bool)
        /// The lookup failed. `denied`: for want of Screen Recording.
        case resolveFailed(denied: Bool)
        /// The stream that was started could not be set up at all.
        case streamSetupFailed
        /// The running stream failed to start, or stopped on its own.
        case streamFailed
        /// A retry's wait is over.
        case retryFired
        /// The pin was taken down for good.
        case removed
    }

    enum Effect: Equatable {
        /// Create and start a stream for the known window.
        case startStream
        case stopStream
        case startFrameSync
        case stopFrameSync
        /// Bring the panel's frame up to date with the window now.
        case syncFrame
        /// Look the window up in ScreenCaptureKit's list.
        case resolveWindow
        /// After `retryDelay`, send `.retryFired`.
        case scheduleRetry
        /// After `behindGrace`, send `.behindGraceElapsed`, replacing any
        /// such wait already under way.
        case scheduleBehindStop
        case cancelBehindStop
        /// Tell the owner that Screen Recording was refused.
        case reportDenied
        /// The retries ran out.
        case gaveUp
    }

    /// Showing over everything, as opposed to waiting behind its window.
    private(set) var pinVisible = false
    /// The system said the pin cannot be seen.
    private(set) var outOfSight = false
    private(set) var streamRunning = false
    /// ScreenCaptureKit has listed the window.
    private(set) var windowKnown = false
    private(set) var resolving = false
    private var resolveStartsStream = false
    private(set) var restarts = 0
    private var lastRevive: TimeInterval = -.infinity
    private(set) var denied = false
    private(set) var removed = false
    private var behindStopPending = false

    mutating func handle(_ event: Event) -> [Effect] {
        guard !removed else { return [] }
        switch event {
        case .created:
            return resolve(thenStart: false)

        case .broughtToFront(let onScreen):
            guard !pinVisible else { return [] }
            var effects: [Effect] = behindStopPending ? [.cancelBehindStop] : []
            behindStopPending = false
            pinVisible = true
            // Whatever was reported while the pin sat invisible behind its
            // window no longer holds. Assume it will be seen; if not, the next
            // report pauses it. Trusting the old answer could leave the pin
            // frozen if the report of it coming into view never arrived.
            outOfSight = false
            restarts = 0
            effects.append(.syncFrame)
            guard onScreen else { return effects }
            return effects + startStream() + [.startFrameSync]

        case .fadedIn:
            guard pinVisible else { return [] }
            return startStream() + [.startFrameSync]

        case .sentBehind:
            guard pinVisible else { return [] }
            pinVisible = false
            behindStopPending = true
            return [.stopFrameSync, .scheduleBehindStop]

        case .behindGraceElapsed:
            behindStopPending = false
            guard !pinVisible else { return [] }
            return stopStream()

        case .occlusion(let hidden):
            return seen(hidden: hidden)

        case .revive(let force, let now, let onScreen, let hidden):
            // What was found is acted on as the system's own report would be.
            // Only noting it let a pin found hidden here keep filming, as the
            // report that followed then looked like no change.
            var effects: [Effect] = []
            if onScreen {
                effects = seen(hidden: hidden)
            } else {
                outOfSight = false
            }
            guard pinVisible, onScreen, !streamRunning, !denied, !outOfSight else { return effects }
            guard force || now - lastRevive >= Self.reviveInterval else { return effects }
            lastRevive = now
            restarts = 0
            return effects + startStream()

        case .resolved(let found):
            let start = resolveStartsStream
            resolving = false
            resolveStartsStream = false
            guard found else { return scheduleResolveRetry(start) }
            windowKnown = true
            return start && pinVisible ? startStream() : []

        case .resolveFailed(let wasDenied):
            let start = resolveStartsStream
            resolving = false
            resolveStartsStream = false
            // Without Screen Recording every retry fails the same way, and on
            // macOS 27 each one puts the permission prompt back up.
            if wasDenied {
                guard !denied else { return [] }
                denied = true
                return [.reportDenied]
            }
            return scheduleResolveRetry(start)

        case .streamSetupFailed:
            streamRunning = false
            return []

        case .streamFailed:
            guard streamRunning else { return [] }
            streamRunning = false
            return restartAfterFailure()

        case .retryFired:
            guard pinVisible, !outOfSight, !streamRunning else { return [] }
            return resolve(thenStart: true)

        case .removed:
            var effects: [Effect] = behindStopPending ? [.cancelBehindStop] : []
            behindStopPending = false
            pinVisible = false
            effects += stopStream() + [.stopFrameSync]
            removed = true
            return effects
        }
    }

    // MARK: - Steps

    /// The pin can or cannot be seen: pause or resume a showing pin.
    private mutating func seen(hidden: Bool) -> [Effect] {
        guard hidden != outOfSight else { return [] }
        outOfSight = hidden
        guard pinVisible else { return [] }
        if hidden { return stopStream() + [.stopFrameSync] }
        return [.syncFrame] + startStream() + [.startFrameSync]
    }

    private mutating func startStream() -> [Effect] {
        guard !streamRunning, !outOfSight, !denied else { return [] }
        guard windowKnown else { return resolve(thenStart: true) }
        streamRunning = true
        return [.startStream]
    }

    /// Stopping always clears the stream's pending reconfiguration too, so
    /// it is sent even with no stream running.
    private mutating func stopStream() -> [Effect] {
        streamRunning = false
        return [.stopStream]
    }

    /// One lookup at a time: several callers ask for the stream to start, and
    /// each used to start a lookup of its own. One already running will do,
    /// and is told to go on to start the stream if this caller needs that.
    private mutating func resolve(thenStart: Bool) -> [Effect] {
        resolveStartsStream = resolveStartsStream || thenStart
        guard !resolving, !denied else { return [] }
        resolving = true
        return [.resolveWindow]
    }

    /// Lookups count against the same limit as stream restarts: a window that
    /// ScreenCaptureKit never lists would otherwise be looked up, in a full
    /// listing of every window, once a second for as long as the pin was up.
    private mutating func scheduleResolveRetry(_ start: Bool) -> [Effect] {
        guard start, restarts < Self.maxRestarts else { return [] }
        restarts += 1
        return [.scheduleRetry]
    }

    /// Try again a moment after the stream failed, rather than leaving the
    /// pin on a frozen frame until it next goes behind and comes back.
    private mutating func restartAfterFailure() -> [Effect] {
        guard pinVisible, !outOfSight, !denied else { return [] }
        guard restarts < Self.maxRestarts else { return [.gaveUp] }
        restarts += 1
        return [.scheduleRetry]
    }
}
