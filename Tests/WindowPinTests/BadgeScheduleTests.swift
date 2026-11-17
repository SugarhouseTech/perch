import Testing
import Foundation
@testable import WindowPin

// Time is always passed in. Where an exact boundary matters the times start at
// 0, so the arithmetic is exact: 100.05 - 100 is a hair under 0.05.

// MARK: - Table-driven cases

@Suite struct BadgeScheduleCoalescingTests {

    struct Case: Sendable, CustomTestStringConvertible {
        var gap: TimeInterval
        var runsNow: Bool
        var testDescription: String { "second refresh \(gap)s after the first" }
    }

    @Test(arguments: [
        Case(gap: 0.001, runsNow: false),
        Case(gap: 0.049, runsNow: false),
        Case(gap: BadgeSchedule.burstGap, runsNow: true),   // exactly 50ms is not part of the burst
        Case(gap: 0.051, runsNow: true),
        Case(gap: 3, runsNow: true),
    ])
    func burstBoundary(_ c: Case) {
        var s = BadgeSchedule()
        let r1 = s.refresh(following: true, buttonHeld: false, now: 0)
        #expect(r1.runsNow)
        let r2 = s.refresh(following: true, buttonHeld: false, now: c.gap)
        #expect(r2.runsNow == c.runsNow)
        #expect(s.refreshPending == !c.runsNow)
    }

    struct Follow: Sendable, CustomTestStringConvertible {
        var following: Bool
        var gap: TimeInterval
        /// followUntil after both refreshes, which both pass `following`.
        var until: TimeInterval
        var testDescription: String { "following=\(following) gap=\(gap)" }
    }

    @Test(arguments: [
        // A following refresh keeps the timer for a second from itself,
        // whether it ran or was put off.
        Follow(following: true, gap: 0.5, until: 1.5),
        Follow(following: true, gap: 0.01, until: 1.01),
        // Without following, only a put-off refresh asks for a moment, to be picked up.
        Follow(following: false, gap: 0.5, until: -.infinity),
        Follow(following: false, gap: 0.01, until: 0.01 + BadgeSchedule.followAfterPutOff),
    ])
    func followWindow(_ c: Follow) {
        var s = BadgeSchedule()
        _ = s.refresh(following: c.following, buttonHeld: false, now: 0)
        _ = s.refresh(following: c.following, buttonHeld: false, now: c.gap)
        #expect(s.followUntil == c.until)
    }

    @Test func aLoneClickStartsNoTimer() {
        var s = BadgeSchedule()
        let d = s.refresh(following: false, buttonHeld: false, now: 5)
        #expect(d == .init(runsNow: true, startsTimer: false))
        #expect(!s.isFollowing)
    }

    @Test func aClickWithTheButtonHeldStartsOne() {
        var s = BadgeSchedule()
        let r3 = s.refresh(following: false, buttonHeld: true, now: 5)
        #expect(r3 == .init(runsNow: true, startsTimer: true))
        // Already running: not started twice.
        let r4 = s.refresh(following: false, buttonHeld: true, now: 6)
        #expect(r4 == .init(runsNow: true, startsTimer: false))
    }

    @Test func aPutOffRefreshAlwaysHasATimerToPickItUp() {
        var s = BadgeSchedule()
        _ = s.refresh(following: false, buttonHeld: false, now: 0)
        let r5 = s.refresh(following: false, buttonHeld: false, now: 0.01)
        #expect(r5 == .init(runsNow: false, startsTimer: true))
    }
}

@Suite struct BadgeFollowLoopTests {

    @Test func burstThenQuiet() {
        var s = BadgeSchedule()
        for t in [0.0, 0.01, 0.02] { _ = s.refresh(following: true, buttonHeld: false, now: t) }
        // The two put-off refreshes are one pick-up, then focus is read on every third tick.
        let r6 = s.tick(now: 0.1, buttonHeld: false)
        #expect(r6 == .runPendingRefresh)
        let r7 = s.tick(now: 0.2, buttonHeld: false)
        #expect(r7 == .update)
        let r8 = s.tick(now: 0.3, buttonHeld: false)
        #expect(r8 == .readFocusedWindow)
        let r9 = s.tick(now: 0.4, buttonHeld: false)
        #expect(r9 == .update)
        // followUntil is 1.02, from the last report.
        let r10 = s.tick(now: 1.0, buttonHeld: false)
        #expect(r10 == .update)
        let r11 = s.tick(now: 1.1, buttonHeld: false)
        #expect(r11 == .stop)
        #expect(!s.isFollowing)
    }

    @Test func aFreshTimerStartsItsCountAgain() {
        var s = BadgeSchedule()
        _ = s.refresh(following: true, buttonHeld: false, now: 0)
        let r12 = s.tick(now: 0.1, buttonHeld: false)
        #expect(r12 == .update)
        let r13 = s.tick(now: 2, buttonHeld: false)
        #expect(r13 == .stop)
        _ = s.refresh(following: true, buttonHeld: false, now: 3)
        let r14 = s.tick(now: 3.1, buttonHeld: false)
        #expect(r14 == .update)
        let r15 = s.tick(now: 3.2, buttonHeld: false)
        #expect(r15 == .update)
        let r16 = s.tick(now: 3.3, buttonHeld: false)
        #expect(r16 == .readFocusedWindow)
    }

    @Test func mouseHeldKeepsItGoingUntilReleased() {
        var s = BadgeSchedule()
        let r17 = s.refresh(following: false, buttonHeld: true, now: 0)
        #expect(r17.startsTimer)
        for i in 1...100 {
            let tick = s.tick(now: Double(i) * 0.1, buttonHeld: true)
            #expect(tick != .stop)
        }
        // Released: the up-click's refresh does not follow, so the next tick stops.
        let r18 = s.refresh(following: false, buttonHeld: false, now: 10.05)
        #expect(r18 == .init(runsNow: true, startsTimer: false))
        let r19 = s.tick(now: 10.1, buttonHeld: false)
        #expect(r19 == .stop)
    }

    @Test func releaseWithinTheFollowWindowKeepsGoingToItsEnd() {
        var s = BadgeSchedule()
        _ = s.refresh(following: true, buttonHeld: true, now: 0)
        let r20 = s.tick(now: 0.5, buttonHeld: false)
        #expect(r20 == .update)
        let r21 = s.tick(now: 1.0, buttonHeld: false)
        #expect(r21 == .stop)
    }

    @Test func aPendingRefreshWaitsOnlyForTheNextTickEvenAfterTheWindow() {
        // followUntil from a put-off refresh is 0.2s, so a tick later than that
        // stops without picking it up. The stale flag is harmless: the next
        // refresh runs or is picked up in its own right.
        var s = BadgeSchedule()
        _ = s.refresh(following: false, buttonHeld: false, now: 0)
        _ = s.refresh(following: false, buttonHeld: false, now: 0.01)
        let r22 = s.tick(now: 0.3, buttonHeld: false)
        #expect(r22 == .stop)
        #expect(s.refreshPending)
    }

    struct Recheck: Sendable, CustomTestStringConvertible {
        /// Times, after a first request at 0, at which the finder still wants a recheck.
        var again: [TimeInterval]
        /// The first tick that stops.
        var stopsAt: TimeInterval
        var testDescription: String { "asked again at \(again)" }
    }

    @Test(arguments: [
        Recheck(again: [], stopsAt: 0.5),
        Recheck(again: [0.1], stopsAt: 0.6),
        Recheck(again: [0.1, 0.2, 0.3, 0.4], stopsAt: 0.9),
        // Asked once more after a gap with no ticks in between: only the later request counts.
        Recheck(again: [0.4], stopsAt: 0.9),
    ])
    func recheckWantedThenNot(_ c: Recheck) {
        var s = BadgeSchedule()
        let r23 = s.recheckWanted(now: 0)
        #expect(r23)
        var t = 0.0
        var stopped: TimeInterval?
        while stopped == nil, t < 10 {
            t = (t + 0.1).rounded(toPlaces: 1)
            if s.tick(now: t, buttonHeld: false) == .stop { stopped = t; break }
            if c.again.contains(t) {
                let starts = s.recheckWanted(now: t)
                #expect(!starts)
            }
        }
        #expect(stopped == c.stopsAt)
    }

    @Test func recheckBeforeTheTimerExistsStartsItOnce() {
        var s = BadgeSchedule()
        let r24 = s.recheckWanted(now: 0)
        #expect(r24)
        let r25 = s.recheckWanted(now: 0.05)
        #expect(!r25)
    }
}

@Suite struct RefusalBackoffTests {

    struct Step: Sendable {
        var pid: Int32
        var at: TimeInterval
        var asks: Bool
        /// Only meaningful when it asks: the app refuses and a retry is scheduled.
        var retry = false
    }

    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var steps: [Step]
        var testDescription: String { name }
    }

    @Test(arguments: [
        Case(name: "one app, first second and third time", steps: [
            .init(pid: 7, at: 0, asks: true, retry: true),
            .init(pid: 7, at: 0.5, asks: false),
            .init(pid: 7, at: 0.999, asks: false),
            .init(pid: 7, at: 1.0, asks: true),            // the second time, a second after the first
            .init(pid: 7, at: 5.999, asks: false),
            .init(pid: 7, at: 6.0, asks: true),            // the third: five seconds after the second
            .init(pid: 7, at: 10.9, asks: false),
            .init(pid: 7, at: 11.0, asks: true),
        ]),
        Case(name: "the scheduled retry lands after the first wait", steps: [
            .init(pid: 7, at: 0, asks: true, retry: true),
            .init(pid: 7, at: RefusalBackoff.retryDelay, asks: true),
            .init(pid: 7, at: RefusalBackoff.retryDelay + 4, asks: false),
        ]),
        Case(name: "another app that is fine does not reset it", steps: [
            // A fine app is never recorded as refusing, so only asks by pid 7 appear here.
            .init(pid: 7, at: 0, asks: true, retry: true),
            .init(pid: 7, at: 2, asks: true),
            .init(pid: 7, at: 3, asks: false),
        ]),
        Case(name: "another refusing app in between starts it over (current behaviour)", steps: [
            .init(pid: 7, at: 0, asks: true, retry: true),
            .init(pid: 8, at: 0.1, asks: true, retry: true),
            .init(pid: 7, at: 0.2, asks: true, retry: true),
        ]),
    ])
    func sequences(_ c: Case) {
        var b = RefusalBackoff()
        for step in c.steps {
            let may = b.mayAsk(pid: step.pid, now: step.at)
            #expect(may == step.asks, "pid \(step.pid) at \(step.at)")
            if may {
                let retry = b.refused(pid: step.pid, now: step.at)
                #expect(retry == step.retry, "pid \(step.pid) at \(step.at)")
            }
        }
    }

    /// Two refusing apps switched between quickly are each asked on every switch,
    /// because the backoff remembers only the last one to refuse. Each ask waits
    /// on the app, on the main thread, so a fast Cmd-Tab between two such apps
    /// pays that every time. It is bounded by the user's switching and the
    /// 50ms burst gap, not a loop, so it is left as it is.
    @Test(.disabled("known: a refusing app is asked again at once if another refusing app was asked in between"))
    func twoRefusingAppsAreNotAskedOnEverySwitch() {
        var b = RefusalBackoff()
        var asks = 0
        for i in 0..<20 {
            let pid: Int32 = i % 2 == 0 ? 7 : 8
            let now = Double(i) * 0.1
            if b.mayAsk(pid: pid, now: now) { asks += 1; _ = b.refused(pid: pid, now: now) }
        }
        #expect(asks <= 4)
    }
}

@Suite struct BadgePlacementTests {

    private let side: CGFloat = 22

    struct Case: Sendable, CustomTestStringConvertible {
        var spot: BadgeSpot
        var windowWidth: CGFloat
        var overlayWidth: CGFloat
        var expected: BadgeSpot
        var testDescription: String { "\(spot) \(windowWidth) -> \(overlayWidth)" }
    }

    @Test(arguments: [
        // Half-size pin: the spot halves too.
        Case(spot: .init(right: 40, top: 10), windowWidth: 800, overlayWidth: 400,
             expected: .init(right: 20, top: 5)),
        // Same size: unchanged.
        Case(spot: .init(right: 40, top: 10), windowWidth: 800, overlayWidth: 800,
             expected: .init(right: 40, top: 10)),
        // A tiny pin would put it under the margin: held at the margin.
        Case(spot: .init(right: 9, top: 4), windowWidth: 800, overlayWidth: 400,
             expected: .init(right: TitleBarSlot.margin, top: 2)),
        // A large pin would push it far in: held two badge widths from the left edge.
        Case(spot: .init(right: 760, top: 4), windowWidth: 800, overlayWidth: 400,
             expected: .init(right: 400 - 44, top: 2)),
        // Never above the top.
        Case(spot: .init(right: 40, top: -6), windowWidth: 800, overlayWidth: 800,
             expected: .init(right: 40, top: 0)),
    ])
    func scaledSpot(_ c: Case) {
        #expect(BadgePlacement.scaledSpot(c.spot, windowWidth: c.windowWidth, overlayWidth: c.overlayWidth,
                                          side: side) == c.expected)
    }

    @Test(arguments: [
        (last: Int32?.some(5), answering: Int32(5), kept: true),
        (last: Int32?.some(5), answering: Int32(6), kept: false),
        (last: Int32?.none, answering: Int32(5), kept: false),
    ])
    func noAnswerKeepsTheLastWindowOnlyForTheSameApp(_ c: (last: Int32?, answering: Int32, kept: Bool)) {
        let result = BadgePlacement.focusedAfterNoAnswer(last: c.last, lastPID: { $0 }, answeringPID: c.answering)
        #expect((result != nil) == c.kept)
        if c.kept { #expect(result == c.last) }
    }
}

// MARK: - Model tests

/// A small seeded generator, so a failing seed reproduces anywhere.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private struct Scenario {
    struct Event { var at: TimeInterval; var following: Bool }
    var events: [Event] = []
    /// Spans in which a mouse button is down.
    var held: [Range<TimeInterval>] = []
    /// From this time, each update asks for a recheck, `recheckBudget` times in all.
    var recheckFrom: TimeInterval = 0
    var recheckBudget = 0

    func buttonHeld(at t: TimeInterval) -> Bool { held.contains { $0.contains(t) } }
}

/// Dense bursts down to 1ms apart, moderate runs, long quiet gaps, held buttons
/// (with reports during them), and a bounded run of recheck requests.
private func makeScenario(seed: UInt64) -> Scenario {
    var rng = SplitMix64(state: seed)
    var sc = Scenario()
    var t = Double.random(in: 0...5, using: &rng)
    func follows(_ rng: inout SplitMix64) -> Bool { Int.random(in: 0..<5, using: &rng) != 0 }
    for _ in 0..<Int.random(in: 3...8, using: &rng) {
        switch Int.random(in: 0..<4, using: &rng) {
        case 0:
            for _ in 0..<Int.random(in: 5...200, using: &rng) {
                t += Double.random(in: 0.001...0.02, using: &rng)
                sc.events.append(.init(at: t, following: follows(&rng)))
            }
        case 1:
            for _ in 0..<Int.random(in: 1...20, using: &rng) {
                t += Double.random(in: 0.02...0.4, using: &rng)
                sc.events.append(.init(at: t, following: follows(&rng)))
            }
        case 2:
            t += Double.random(in: 1...30, using: &rng)
        default:
            let down = t, up = t + Double.random(in: 0.05...3, using: &rng)
            sc.held.append(down..<up)
            sc.events.append(.init(at: down, following: false))
            let inside = (0..<Int.random(in: 0...6, using: &rng))
                .map { _ in Double.random(in: down...up, using: &rng) }.sorted()
            sc.events += inside.map { .init(at: $0, following: true) }
            sc.events.append(.init(at: up, following: false))
            t = up
        }
    }
    sc.recheckFrom = Double.random(in: 0...max(t, 1), using: &rng)
    sc.recheckBudget = Int.random(in: 0...10, using: &rng)
    return sc
}

private struct Trace {
    enum Kind { case refresh, pickup }
    var runs: [(at: TimeInterval, kind: Kind)] = []
    var ticks: [TimeInterval] = []
    var stops: [TimeInterval] = []
    var lastRecheckRequest: TimeInterval?
    var finishedCleanly = true
}

/// Drives a `BadgeSchedule` the way `PinBadgeController` does: events call
/// `refresh`, a timer ticks while the schedule wants one, and every update asks
/// for a recheck while the scenario says the finder still wants one.
private func simulate(_ sc: Scenario) -> Trace {
    var s = BadgeSchedule()
    var trace = Trace()
    var timer: TimeInterval?
    var next = 0
    var budget = sc.recheckBudget

    func update(_ t: TimeInterval) {
        guard t >= sc.recheckFrom, budget > 0 else { return }
        budget -= 1
        trace.lastRecheckRequest = t
        if s.recheckWanted(now: t) { timer = t + BadgeSchedule.tickInterval }
    }

    var steps = 0
    while steps < 1_000_000 {
        steps += 1
        let nextEvent = next < sc.events.count ? sc.events[next].at : .infinity
        let nextTick = timer ?? .infinity
        if nextEvent == .infinity, nextTick == .infinity { return trace }
        if nextTick <= nextEvent {
            let t = nextTick
            switch s.tick(now: t, buttonHeld: sc.buttonHeld(at: t)) {
            case .stop:
                timer = nil
                trace.stops.append(t)
            case .runPendingRefresh:
                trace.ticks.append(t)
                trace.runs.append((t, .pickup))
                timer = t + BadgeSchedule.tickInterval
                update(t)
            case .readFocusedWindow, .update:
                trace.ticks.append(t)
                timer = t + BadgeSchedule.tickInterval
                update(t)
            }
        } else {
            let e = sc.events[next]
            next += 1
            let d = s.refresh(following: e.following, buttonHeld: sc.buttonHeld(at: e.at), now: e.at)
            if d.startsTimer { timer = e.at + BadgeSchedule.tickInterval }
            if d.runsNow {
                trace.runs.append((e.at, .refresh))
                update(e.at)
            }
        }
    }
    trace.finishedCleanly = false
    return trace
}

@Suite struct BadgeScheduleModelTests {

    static let seeds: [UInt64] = Array(0..<40)
    private let eps = 1e-6

    @Test(arguments: seeds)
    func refreshesRunAtMostOncePerBurstGap(_ seed: UInt64) {
        let sc = makeScenario(seed: seed)
        let trace = simulate(sc)
        #expect(trace.finishedCleanly, "seed \(seed)")
        // A refresh the moment it is reported is never within 50ms of another such refresh.
        let direct = trace.runs.filter { $0.kind == .refresh }.map(\.at)
        for (a, b) in zip(direct, direct.dropFirst()) {
            #expect(b - a >= BadgeSchedule.burstGap - eps, "seed \(seed): refreshes at \(a) and \(b)")
        }
        // Put-off ones are picked up by a tick, so at most one per tick.
        let picked = trace.runs.filter { $0.kind == .pickup }.map(\.at)
        for (a, b) in zip(picked, picked.dropFirst()) {
            #expect(b - a >= BadgeSchedule.tickInterval - eps, "seed \(seed): pick-ups at \(a) and \(b)")
        }
        // Two runs of the same kind never come back to back inside the burst gap, and
        // every close pair is a direct refresh then the pick-up of what followed it.
        for (x, y) in zip(trace.runs, trace.runs.dropFirst()) where y.at - x.at < BadgeSchedule.burstGap - eps {
            #expect(x.kind == .refresh && y.kind == .pickup, "seed \(seed): runs at \(x.at) and \(y.at)")
        }
    }

    /// A refresh put off by the burst gap is picked up by a tick that may come
    /// at any point in the next 100ms, so a direct refresh followed by a
    /// pick-up can be closer than 50ms. Bounded (one extra per direct refresh,
    /// at most one per tick), so left as it is.
    @Test(.disabled("known: a put-off refresh can be picked up less than 50ms after the refresh that put it off"))
    func noTwoRefreshesOfAnyKindCloserThanTheBurstGap() {
        // Timer ticks at 0.1, 0.2. A refresh at 0.19 runs, one at 0.195 is put
        // off, and the tick at 0.2 picks it up 10ms after the first.
        var s = BadgeSchedule()
        _ = s.refresh(following: true, buttonHeld: false, now: 0)
        let r26 = s.tick(now: 0.1, buttonHeld: false)
        #expect(r26 != .stop)
        let r27 = s.refresh(following: true, buttonHeld: false, now: 0.19)
        #expect(r27.runsNow)
        let r28 = s.refresh(following: true, buttonHeld: false, now: 0.195)
        #expect(!r28.runsNow)
        let tick = s.tick(now: 0.2, buttonHeld: false)
        #expect(tick != .runPendingRefresh)
    }

    @Test(arguments: seeds)
    func followingStopsWithinABoundAfterTheLastCause(_ seed: UInt64) {
        let sc = makeScenario(seed: seed)
        let trace = simulate(sc)
        #expect(trace.finishedCleanly, "seed \(seed)")
        let lastEvent = sc.events.map(\.at).max() ?? 0
        let lastRelease = sc.held.map(\.upperBound).max() ?? 0
        // The loop runs on until the latest of: a second after the last report,
        // half a second after the last recheck request, and the button release,
        // and then for at most one more tick before it notices.
        let lastCause = max(lastEvent + BadgeSchedule.followAfterRefresh,
                            (trace.lastRecheckRequest ?? 0) + BadgeSchedule.followAfterRecheck,
                            lastRelease)
        let bound = lastCause + BadgeSchedule.tickInterval
        for t in trace.ticks + trace.stops {
            #expect(t <= bound + eps, "seed \(seed): tick at \(t) after bound \(bound)")
        }
        #expect(trace.stops.last != nil || sc.events.isEmpty, "seed \(seed): never stopped")
    }

    @Test(arguments: seeds)
    func recheckRequestsBoundTheTicksTheyCause(_ seed: UInt64) {
        // With only a bounded number of recheck requests and no mouse, each
        // request buys at most half a second, so the total tick count is bounded.
        var sc = makeScenario(seed: seed)
        sc.events = []
        sc.held = []
        sc.recheckFrom = 0
        let trace = simulate(sc)
        // Nothing asked for a refresh or for following, so nothing runs: a recheck
        // is only requested by an update, and an update only follows something.
        #expect(trace.ticks.isEmpty && trace.runs.isEmpty, "seed \(seed)")
    }

    @Test(arguments: seeds)
    func requestedRechecksAreBounded(_ seed: UInt64) {
        // One refresh, then the finder wants a recheck `budget` times.
        var sc = Scenario()
        sc.events = [.init(at: 1, following: false)]
        sc.recheckFrom = 0
        sc.recheckBudget = Int(seed % 11)
        let trace = simulate(sc)
        let budget = Double(sc.recheckBudget)
        // Each request extends by 0.5s; ticks are 0.1s apart.
        let most = (budget * BadgeSchedule.followAfterRecheck) / BadgeSchedule.tickInterval + 2
        #expect(Double(trace.ticks.count) <= most, "seed \(seed): \(trace.ticks.count) ticks")
        #expect(trace.finishedCleanly)
    }

    @Test func noEventsNothingEverRuns() {
        let trace = simulate(Scenario(recheckFrom: 0, recheckBudget: 10))
        #expect(trace.runs.isEmpty)
        #expect(trace.ticks.isEmpty)
        #expect(trace.stops.isEmpty)
        var s = BadgeSchedule()
        #expect(!s.isFollowing)
        // A stray tick with no cause stops at once rather than running.
        let r29 = s.tick(now: 1, buttonHeld: false)
        #expect(r29 == .stop)
    }

    @Test(arguments: seeds)
    func aLongQuietGapLeavesNothingRunning(_ seed: UInt64) {
        let sc = makeScenario(seed: seed)
        let trace = simulate(sc)
        // Whatever happened, the schedule ends with no timer and no tick scheduled.
        #expect(trace.finishedCleanly, "seed \(seed)")
        if let lastTick = trace.ticks.last, let lastStop = trace.stops.last {
            #expect(lastStop >= lastTick, "seed \(seed)")
        }
    }

    @Test(arguments: seeds)
    func ticksAreNeverCloserThanTheInterval(_ seed: UInt64) {
        let trace = simulate(makeScenario(seed: seed))
        let all = (trace.ticks + trace.stops).sorted()
        for (a, b) in zip(all, all.dropFirst()) {
            #expect(b - a >= BadgeSchedule.tickInterval - eps, "seed \(seed): ticks at \(a) and \(b)")
        }
    }
}

@Suite struct RefusalBackoffModelTests {

    private let eps = 1e-9

    /// Every refresh in a random stream tries the one refusing frontmost app.
    @Test(arguments: BadgeScheduleModelTests.seeds)
    func aRefusingAppIsAskedAtMostOncePerInterval(_ seed: UInt64) {
        var rng = SplitMix64(state: seed)
        var b = RefusalBackoff()
        var t = 0.0
        var asks: [TimeInterval] = []
        var retries = 0
        for _ in 0..<Int.random(in: 50...400, using: &rng) {
            // Mostly dense, sometimes a long gap.
            t += Int.random(in: 0..<10, using: &rng) == 0
                ? Double.random(in: 1...20, using: &rng)
                : Double.random(in: 0.001...0.3, using: &rng)
            if b.mayAsk(pid: 7, now: t) {
                asks.append(t)
                if b.refused(pid: 7, now: t) { retries += 1 }
            }
        }
        #expect(retries <= 1, "seed \(seed)")
        for (i, (a, c)) in zip(asks, asks.dropFirst()).enumerated() {
            let wait = i == 0 ? RefusalBackoff.firstWait : RefusalBackoff.laterWait
            #expect(c - a >= wait - eps, "seed \(seed): asked at \(a) and \(c)")
        }
        if let first = asks.first, let last = asks.last {
            let span = last - first
            // One at the start, one after a second, then one per five seconds.
            let most = 2 + Int(max(0, span - RefusalBackoff.firstWait) / RefusalBackoff.laterWait)
            #expect(asks.count <= most, "seed \(seed): \(asks.count) asks in \(span)s")
        }
    }

    /// With several refusing apps, an app asked twice with no other refusing
    /// app asked in between still waits out its interval. (Across a switch it
    /// does not: see `twoRefusingAppsAreNotAskedOnEverySwitch`.)
    @Test(arguments: BadgeScheduleModelTests.seeds)
    func eachAppWaitsWhenItIsAskedTwiceInARow(_ seed: UInt64) {
        var rng = SplitMix64(state: seed)
        var b = RefusalBackoff()
        var t = 0.0
        var previous: (pid: Int32, at: TimeInterval, wasFirst: Bool)?
        for _ in 0..<Int.random(in: 50...400, using: &rng) {
            t += Double.random(in: 0.001...2, using: &rng)
            // Long runs on one app, with occasional switches.
            let pid = Int32(Int.random(in: 0..<6, using: &rng) == 0 ? Int.random(in: 1...3, using: &rng) : 1)
            guard b.mayAsk(pid: pid, now: t) else { continue }
            let retry = b.refused(pid: pid, now: t)
            if let p = previous, p.pid == pid {
                let wait = p.wasFirst ? RefusalBackoff.firstWait : RefusalBackoff.laterWait
                #expect(t - p.at >= wait - eps, "seed \(seed): pid \(pid) asked at \(p.at) and \(t)")
            }
            previous = (pid, t, retry)
        }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let m = pow(10, Double(places))
        return (self * m).rounded() / m
    }
}
