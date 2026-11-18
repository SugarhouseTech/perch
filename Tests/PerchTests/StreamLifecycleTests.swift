import Foundation
import Testing
@testable import Perch

private typealias L = StreamLifecycle

/// A pin whose window is already known, as it is a moment after pinning.
private func knownPin() -> L {
    var life = L()
    _ = life.handle(.created)
    _ = life.handle(.resolved(found: true))
    return life
}

/// A known pin showing over everything with its stream running.
private func showingPin() -> L {
    var life = knownPin()
    _ = life.handle(.broughtToFront(onScreen: false))
    _ = life.handle(.fadedIn)
    return life
}

@Suite struct StreamLifecycleScenarioTests {

    @Test func aNewPinLooksItsWindowUpButFilmsNothing() {
        var life = L()
        #expect(life.handle(.created) == [.resolveWindow])
        #expect(life.handle(.resolved(found: true)) == [])
        #expect(!life.streamRunning)
    }

    @Test func theFirstShowingStartsTheStreamOnceFadedIn() {
        var life = knownPin()
        #expect(life.handle(.broughtToFront(onScreen: false)) == [.syncFrame])
        #expect(life.handle(.fadedIn) == [.startStream, .startFrameSync])
        #expect(life.streamRunning)
    }

    @Test func raisingAPinAlreadyOnScreenStartsItsStream() {
        var life = knownPin()
        #expect(life.handle(.broughtToFront(onScreen: true)) == [.syncFrame, .startStream, .startFrameSync])
    }

    @Test func raisingItTwiceDoesNothingTheSecondTime() {
        var life = showingPin()
        #expect(life.handle(.broughtToFront(onScreen: true)) == [])
    }

    @Test func shownBeforeItsWindowIsFoundItStartsOnceFound() {
        var life = L()
        #expect(life.handle(.created) == [.resolveWindow])
        // Shown while the first lookup is still under way: no second lookup.
        #expect(life.handle(.broughtToFront(onScreen: false)) == [.syncFrame])
        #expect(life.handle(.fadedIn) == [.startFrameSync])
        // That lookup now goes on to start the stream.
        #expect(life.handle(.resolved(found: true)) == [.startStream])
    }

    @Test func goingBehindKeepsTheStreamForAMoment() {
        var life = showingPin()
        #expect(life.handle(.sentBehind) == [.stopFrameSync, .scheduleBehindStop])
        #expect(life.streamRunning)
        #expect(life.handle(.behindGraceElapsed) == [.stopStream])
        #expect(!life.streamRunning)
    }

    @Test func comingBackWithinTheGraceReusesTheStream() {
        var life = showingPin()
        _ = life.handle(.sentBehind)
        #expect(life.handle(.broughtToFront(onScreen: true)) == [.cancelBehindStop, .syncFrame, .startFrameSync])
        // A grace that fires anyway, having been cancelled too late, stops nothing.
        #expect(life.handle(.behindGraceElapsed) == [])
        #expect(life.streamRunning)
    }

    @Test func goingOutOfSightPausesAndComingBackResumes() {
        var life = showingPin()
        #expect(life.handle(.occlusion(hidden: true)) == [.stopStream, .stopFrameSync])
        #expect(life.handle(.occlusion(hidden: true)) == [], "the same report twice")
        #expect(life.handle(.occlusion(hidden: false)) == [.syncFrame, .startStream, .startFrameSync])
    }

    @Test func outOfSightBehindItsWindowChangesNothingUntilShown() {
        var life = knownPin()
        #expect(life.handle(.occlusion(hidden: true)) == [])
        // Shown again: the old report is not trusted.
        #expect(life.handle(.broughtToFront(onScreen: true)) == [.syncFrame, .startStream, .startFrameSync])
    }

    @Test func aFailingStreamIsRetriedFiveTimesThenLeft() {
        var life = showingPin()
        for _ in 0..<L.maxRestarts {
            #expect(life.handle(.streamFailed) == [.scheduleRetry])
            #expect(life.handle(.retryFired) == [.resolveWindow])
            #expect(life.handle(.resolved(found: true)) == [.startStream])
        }
        #expect(life.handle(.streamFailed) == [.gaveUp])
        #expect(!life.streamRunning)
    }

    @Test func aWindowNeverListedIsLookedUpAtMostFiveTimesMore() {
        var life = L()
        _ = life.handle(.created)
        _ = life.handle(.broughtToFront(onScreen: false))
        _ = life.handle(.fadedIn)
        var lookups = 0
        for _ in 0..<20 {
            let effects = life.handle(.resolved(found: false))
            guard effects == [.scheduleRetry] else { break }
            #expect(life.handle(.retryFired) == [.resolveWindow])
            lookups += 1
        }
        #expect(lookups == L.maxRestarts)
    }

    @Test func aReviveGivesAFreshSetOfRetries() {
        var life = showingPin()
        for _ in 0..<L.maxRestarts {
            _ = life.handle(.streamFailed)
            _ = life.handle(.retryFired)
            _ = life.handle(.resolved(found: true))
        }
        _ = life.handle(.streamFailed)
        #expect(life.handle(.revive(force: true, now: 100, onScreen: true, hidden: false)) == [.startStream])
        #expect(life.restarts == 0)
    }

    @Test func aReviveNotAskedForIsHeldToOnceEveryHalfMinute() {
        var life = showingPin()
        _ = life.handle(.streamFailed)
        _ = life.handle(.retryFired)
        _ = life.handle(.resolved(found: false))
        #expect(life.handle(.revive(force: false, now: 100, onScreen: true, hidden: false)) == [.startStream])
        _ = life.handle(.streamFailed)
        #expect(life.handle(.revive(force: false, now: 129, onScreen: true, hidden: false)) == [])
        #expect(life.handle(.revive(force: true, now: 129, onScreen: true, hidden: false)) == [.startStream])
        _ = life.handle(.streamFailed)
        #expect(life.handle(.revive(force: false, now: 159.5, onScreen: true, hidden: false)) == [.startStream])
    }

    @Test func aReviveLeavesARunningStreamAlone() {
        var life = showingPin()
        #expect(life.handle(.revive(force: true, now: 1, onScreen: true, hidden: false)) == [])
    }

    @Test func aReviveLeavesAPinNotYetOnScreen() {
        var life = showingPin()
        _ = life.handle(.streamFailed)
        #expect(life.handle(.revive(force: true, now: 1, onScreen: false, hidden: false)) == [])
    }

    @Test func aReviveOfAHiddenPinRecordsItAsOutOfSight() {
        var life = showingPin()
        _ = life.handle(.streamFailed)
        #expect(life.handle(.revive(force: true, now: 1, onScreen: true, hidden: true)) == [.stopStream, .stopFrameSync])
        #expect(life.outOfSight)
        #expect(life.handle(.retryFired) == [], "no retry while out of sight")
    }

    @Test func aReviveThatFindsAFilmingPinHiddenStopsItsStream() {
        // Found hidden by a revive before the system's report came: the
        // report then changes nothing, so the revive has to pause it.
        var life = showingPin()
        #expect(life.handle(.revive(force: false, now: 1, onScreen: true, hidden: true)) == [.stopStream, .stopFrameSync])
        #expect(!life.streamRunning)
        #expect(life.handle(.occlusion(hidden: true)) == [])
        #expect(life.handle(.revive(force: false, now: 2, onScreen: true, hidden: false))
                == [.syncFrame, .startStream, .startFrameSync])
    }

    @Test func aFadeInForAPinSentBehindMeanwhileStartsNothing() {
        var life = knownPin()
        _ = life.handle(.broughtToFront(onScreen: false))
        _ = life.handle(.sentBehind)
        #expect(life.handle(.fadedIn) == [])
    }

    @Test func refusedScreenRecordingIsReportedOnceAndNeverAskedAgain() {
        var life = L()
        _ = life.handle(.created)
        #expect(life.handle(.resolveFailed(denied: true)) == [.reportDenied])
        _ = life.handle(.broughtToFront(onScreen: false))
        #expect(life.handle(.fadedIn) == [.startFrameSync])
        #expect(life.handle(.revive(force: true, now: 1, onScreen: true, hidden: false)) == [])
        #expect(life.handle(.resolveFailed(denied: true)) == [])
    }

    @Test func aStreamFailingAfterARefusalIsNotRetried() {
        var life = showingPin()
        _ = life.handle(.resolveFailed(denied: true))
        #expect(life.handle(.streamFailed) == [])
    }

    @Test func aRemovedPinStopsEverythingAndHearsNothingMore() {
        var life = showingPin()
        _ = life.handle(.sentBehind)
        #expect(life.handle(.removed) == [.cancelBehindStop, .stopStream, .stopFrameSync])
        for event: L.Event in [.broughtToFront(onScreen: true), .fadedIn, .resolved(found: true),
                               .retryFired, .behindGraceElapsed, .occlusion(hidden: false),
                               .revive(force: true, now: 1, onScreen: true, hidden: false), .streamFailed] {
            #expect(life.handle(event) == [], "\(event)")
        }
    }

    @Test func aStreamThatCouldNotBeSetUpIsNotCountedAsRunning() {
        var life = knownPin()
        _ = life.handle(.broughtToFront(onScreen: true))
        _ = life.handle(.streamSetupFailed)
        #expect(!life.streamRunning)
        #expect(life.handle(.occlusion(hidden: true)) == [.stopStream, .stopFrameSync])
        #expect(life.handle(.occlusion(hidden: false)) == [.syncFrame, .startStream, .startFrameSync])
    }
}

/// Drives the lifecycle as the overlay and the system would: the user
/// switching apps, the system reporting the pin hidden and shown, and the
/// late answers of ScreenCaptureKit and of timers arriving in any order,
/// some after the pin has moved on. Checks the rules that keep a pin from
/// filming twice, filming for nobody, or retrying for ever.
@Suite struct StreamLifecycleModelTests {

    /// The world outside the lifecycle: what is really running and pending.
    private struct World {
        var life = L()
        var streamRunning = false
        var lookupsInFlight = 0
        var retriesPending = 0
        var behindPending = false
        var onScreen = false
        var awaitingFadeIn = false
        var now: TimeInterval = 0
        var removedAt: Int?
        var denied = false
        /// Retries scheduled since the last fresh start.
        var retriesSinceFresh = 0
        var lastUnforcedRevive: TimeInterval?
    }

    @Test(arguments: 0..<40)
    func randomHistoriesKeepTheRules(seed: Int) {
        var rng = SeededGenerator(seed: UInt64(seed))
        var w = World()
        apply(.created, to: &w, step: 0, seed: seed)
        for step in 1...600 {
            w.now += Double.random(in: 0.01...4, using: &rng)
            let event = nextEvent(&w, &rng)
            apply(event, to: &w, step: step, seed: seed)
        }
    }

    private func nextEvent(_ w: inout World, _ rng: inout SeededGenerator) -> L.Event {
        // Late answers first, at random, so they land in every order.
        var late: [L.Event] = []
        if w.lookupsInFlight > 0 {
            if w.denied || Int.random(in: 0..<12, using: &rng) == 0 {
                late.append(.resolveFailed(denied: Int.random(in: 0..<4, using: &rng) == 0))
            } else {
                late.append(.resolved(found: Int.random(in: 0..<4, using: &rng) != 0))
            }
        }
        if w.retriesPending > 0 { late.append(.retryFired) }
        if w.behindPending || Int.random(in: 0..<30, using: &rng) == 0 { late.append(.behindGraceElapsed) }
        if w.streamRunning, Int.random(in: 0..<5, using: &rng) == 0 { late.append(.streamFailed) }
        if w.awaitingFadeIn { late.append(.fadedIn) }
        if !late.isEmpty, Bool.random(using: &rng) { return late.randomElement(using: &rng)! }

        switch Int.random(in: 0..<100, using: &rng) {
        case 0..<30: return .broughtToFront(onScreen: w.onScreen)
        case 30..<55: return .sentBehind
        case 55..<70: return .occlusion(hidden: Bool.random(using: &rng))
        case 70..<88: return .revive(force: Int.random(in: 0..<4, using: &rng) == 0, now: w.now,
                                     onScreen: w.onScreen, hidden: Int.random(in: 0..<5, using: &rng) == 0)
        case 88..<89: return .removed
        case 89..<92: return .streamSetupFailed
        default: return late.randomElement(using: &rng) ?? .sentBehind
        }
    }

    private func apply(_ event: L.Event, to w: inout World, step: Int, seed: Int) {
        let context = "seed \(seed) step \(step) \(event)"
        // Account for the late answer being consumed.
        switch event {
        case .resolved, .resolveFailed:
            guard w.lookupsInFlight > 0 else { return }
            w.lookupsInFlight -= 1
            if case .resolveFailed(true) = event { w.denied = true }
        case .retryFired:
            guard w.retriesPending > 0 else { return }
            w.retriesPending -= 1
        case .streamFailed:
            guard w.streamRunning else { return }
            w.streamRunning = false
        case .streamSetupFailed:
            // Only ever reported right after a start was asked for.
            return
        case .fadedIn:
            guard w.awaitingFadeIn else { return }
            w.awaitingFadeIn = false
            w.onScreen = true
        case .behindGraceElapsed:
            w.behindPending = false
        default: break
        }
        let wasVisible = w.life.pinVisible
        let effects = w.life.handle(event)

        if case .broughtToFront(let onScreen) = event, !wasVisible, w.removedAt == nil {
            w.retriesSinceFresh = 0
            if !onScreen { w.awaitingFadeIn = true }
        }
        // A revive proper starts the stream and nothing else; a resume from
        // being out of sight comes with a frame sync and is not throttled.
        if case .revive(let force, let now, _, _) = event, effects == [.startStream] {
            w.retriesSinceFresh = 0
            if !force {
                if let last = w.lastUnforcedRevive {
                    #expect(now - last >= L.reviveInterval, "unforced revives too close, \(context)")
                }
                w.lastUnforcedRevive = now
            }
        }
        if case .removed = event { w.removedAt = w.removedAt ?? step; w.awaitingFadeIn = false }

        for effect in effects {
            if w.removedAt != nil, w.removedAt! < step {
                #expect(effect != .startStream && effect != .resolveWindow && effect != .scheduleRetry,
                        "\(effect) after removal, \(context)")
            }
            switch effect {
            case .startStream:
                #expect(!w.streamRunning, "a second stream, \(context)")
                #expect(!w.life.outOfSight, "filming out of sight, \(context)")
                w.streamRunning = true
            case .stopStream:
                w.streamRunning = false
            case .resolveWindow:
                #expect(w.lookupsInFlight == 0, "two lookups at once, \(context)")
                #expect(!w.denied, "asked again after a refusal, \(context)")
                w.lookupsInFlight += 1
            case .scheduleRetry:
                w.retriesPending += 1
                w.retriesSinceFresh += 1
                #expect(w.retriesSinceFresh <= L.maxRestarts, "retries past the limit, \(context)")
            case .scheduleBehindStop:
                w.behindPending = true
            case .cancelBehindStop:
                w.behindPending = false
            default: break
            }
        }
        #expect(w.streamRunning == w.life.streamRunning, "lifecycle lost track of the stream, \(context)")
        // A stream runs only for a pin that is showing and can be seen, or in
        // the grace after it went behind.
        if w.streamRunning {
            #expect((w.life.pinVisible && !w.life.outOfSight) || w.behindPending,
                    "filming for nobody, \(context)")
        }
    }
}
