import Testing
@testable import Perch

private let missing: Bool? = false
private let present: Bool? = true
private let failed: Bool? = nil

@Suite struct PrunePolicyTests {

    /// One pass of the policy over a single pin; `quietUntil` 0 means no
    /// quiet period.
    private func step(_ lookup: Bool?, strikes: Set<UInt32>,
                      now: Double = 100, quietUntil: Double = 0, onConsole: Bool = true)
        -> PinPolicy.PruneOutcome {
        PinPolicy.prune(pinned: [1], lookups: [1: lookup], missingOnce: strikes,
                        now: now, quietUntil: quietUntil, onConsole: onConsole)
    }

    struct Case: CustomTestStringConvertible {
        let name: String
        let lookup: Bool?
        let strikes: Set<UInt32>
        let removed: Set<UInt32>
        let nextStrikes: Set<UInt32>
        var testDescription: String { name }
    }

    @Test(arguments: [
        Case(name: "present, no strikes", lookup: present, strikes: [], removed: [], nextStrikes: []),
        Case(name: "present clears a strike", lookup: present, strikes: [1], removed: [], nextStrikes: []),
        Case(name: "first miss is only a strike", lookup: missing, strikes: [], removed: [], nextStrikes: [1]),
        Case(name: "second miss in a row removes", lookup: missing, strikes: [1], removed: [1], nextStrikes: [1]),
        Case(name: "failed lookup removes nothing", lookup: failed, strikes: [], removed: [], nextStrikes: []),
        Case(name: "failed lookup breaks a streak", lookup: failed, strikes: [1], removed: [], nextStrikes: []),
    ])
    func lookups(_ c: Case) {
        let out = step(c.lookup, strikes: c.strikes)
        #expect(out.remove == c.removed)
        #expect(out.missingOnce == c.nextStrikes)
    }

    @Test func windowThatReappearsBetweenStrikesIsKept() {
        var strikes: Set<UInt32> = []
        for lookup in [missing, present, missing] {
            let out = step(lookup, strikes: strikes)
            #expect(out.remove.isEmpty)
            strikes = out.missingOnce
        }
        #expect(strikes == [1])
    }

    @Test func pinWithNoLookupCountsAsFailed() {
        let out = PinPolicy.prune(pinned: [1], lookups: [:], missingOnce: [1],
                                  now: 100, quietUntil: 0, onConsole: true)
        #expect(out.remove.isEmpty)
        #expect(out.missingOnce.isEmpty)
    }

    @Test(arguments: [
        (now: 99.9, pruned: false),
        (now: 100.0, pruned: true),   // exactly at the deadline counts as over
        (now: 100.1, pruned: true),
        (now: 0.0, pruned: false),
    ])
    func quietDeadline(now: Double, pruned: Bool) {
        let out = step(missing, strikes: [1], now: now, quietUntil: 100)
        #expect(out.remove == (pruned ? [1] : []))
    }

    @Test func aQuietPassStartsTheCountAgain() {
        let out = step(missing, strikes: [1], now: 5, quietUntil: 100)
        #expect(out.missingOnce.isEmpty)
        #expect(out.remove.isEmpty)
    }

    @Test func anOffConsolePassStartsTheCountAgain() {
        let out = step(missing, strikes: [1], onConsole: false)
        #expect(out.remove.isEmpty)
        #expect(out.missingOnce.isEmpty)
    }

    @Test func aMissBeforeSleepAndOneAfterIsNotTwoInARow() {
        let before = step(missing, strikes: [], now: 0, quietUntil: 0)
        #expect(before.missingOnce == [1])
        let asleep = step(missing, strikes: before.missingOnce, now: 5, quietUntil: 10)
        let after = step(missing, strikes: asleep.missingOnce, now: 11, quietUntil: 10)
        #expect(after.remove.isEmpty)
        #expect(after.missingOnce == [1])
    }

    @Test func mayPruneNeedsQuietOverAndConsole() {
        #expect(PinPolicy.mayPrune(now: 10, quietUntil: 10, onConsole: true))
        #expect(!PinPolicy.mayPrune(now: 10, quietUntil: 10, onConsole: false))
        #expect(!PinPolicy.mayPrune(now: 9, quietUntil: 10, onConsole: true))
    }

    @Test func severalPinsAreJudgedIndependently() {
        // 1: second miss. 2: first miss. 3: failed. 4: present. 5: reappeared.
        let out = PinPolicy.prune(
            pinned: [1, 2, 3, 4, 5],
            lookups: [1: missing, 2: missing, 3: failed, 4: present, 5: present],
            missingOnce: [1, 3, 5],
            now: 100, quietUntil: 0, onConsole: true)
        #expect(out.remove == [1])
        #expect(out.missingOnce == [1, 2])
    }

    @Test func strikesForUnpinnedWindowsAreDropped() {
        let out = PinPolicy.prune(pinned: [1], lookups: [1: present], missingOnce: [9],
                                  now: 100, quietUntil: 0, onConsole: true)
        #expect(out.missingOnce.isEmpty)
        #expect(out.remove.isEmpty)
    }
}

@Suite struct LayeringPolicyTests {

    @Test(arguments: [
        (cropped: true, owner: Int32(1), activated: Int32(1), expected: ActivationAction.decideByLayering),
        (cropped: true, owner: 1, activated: 2, expected: .decideByLayering),
        (cropped: false, owner: 1, activated: 1, expected: .change(.sendBehind)),
        (cropped: false, owner: 1, activated: 2, expected: .change(.bringToFront)),
    ])
    func activation(cropped: Bool, owner: Int32, activated: Int32, expected: ActivationAction) {
        #expect(PinPolicy.activationAction(isCropped: cropped, ownerPID: owner,
                                           activatedPID: activated) == expected)
    }

    @Test(arguments: [
        (inUse: true, visible: true, expected: PinLayerChange?.some(.sendBehind)),
        (inUse: false, visible: false, expected: .some(.bringToFront)),
        (inUse: true, visible: false, expected: nil),
        (inUse: false, visible: true, expected: nil),
    ])
    func layering(inUse: Bool, visible: Bool, expected: PinLayerChange?) {
        #expect(PinPolicy.layeringChange(inUse: inUse, visible: visible) == expected)
    }

    @Test func timerRunsOnlyForACroppedPinWhoseAppIsInFront() {
        let pins: [(isCropped: Bool, targetPID: Int32)] = [(false, 1), (true, 2), (false, 3)]
        #expect(PinPolicy.layeringTimerNeeded(pins: pins, frontPID: 2))
        #expect(!PinPolicy.layeringTimerNeeded(pins: pins, frontPID: 1))  // that pin is not cropped
        #expect(!PinPolicy.layeringTimerNeeded(pins: pins, frontPID: 9))
        #expect(!PinPolicy.layeringTimerNeeded(pins: pins, frontPID: nil))
        #expect(!PinPolicy.layeringTimerNeeded(pins: [], frontPID: 2))
    }
}
@Suite struct PruneModelTests {

    /// Drives the policy as the tracker does over random histories and checks
    /// each pin against a plain count of consecutive "gone" answers on passes
    /// allowed to act, with a gated pass in between starting the count over.
    ///
    /// Window 1 is only ever present or failed. Window 2 answers at random.
    /// Window 3 starts answering "gone" for good at a random pass.
    @Test func randomHistoriesKeepTheInvariants() {
        for seed in UInt64(1)...3000 {
            var rng = SeededGenerator(seed: seed)
            var pinned: Set<UInt32> = [1, 2, 3]
            var strikes: Set<UInt32> = []
            var streak: [UInt32: Int] = [:]
            /// Acting passes in a row since window 3 left: a gated pass starts it over.
            var actingPassesSinceLeft = 0
            let leavesAt = Int.random(in: 0..<20, using: &rng)
            var now = 0.0
            var quietUntil = 0.0

            for pass in 0..<60 {
                now += 2
                if Int.random(in: 0..<8, using: &rng) == 0 { quietUntil = now + 10 }
                let onConsole = Int.random(in: 0..<6, using: &rng) != 0
                let acting = PinPolicy.mayPrune(now: now, quietUntil: quietUntil, onConsole: onConsole)
                let context = "seed \(seed) pass \(pass)"

                var lookups: [UInt32: Bool?] = [:]
                for id in pinned {
                    if id == 3, pass >= leavesAt {
                        lookups[id] = missing
                        continue
                    }
                    switch Int.random(in: 0..<10, using: &rng) {
                    case 0...5: lookups[id] = present
                    case 6...7: lookups[id] = id == 1 ? present : missing
                    default: lookups[id] = failed
                    }
                }

                let out = PinPolicy.prune(pinned: pinned, lookups: lookups, missingOnce: strikes,
                                          now: now, quietUntil: quietUntil, onConsole: onConsole)
                #expect(out.remove.isSubset(of: pinned), "\(context)")
                if !acting {
                    #expect(out.remove.isEmpty, "removed while gated, \(context)")
                    #expect(out.missingOnce.isEmpty, "strikes kept through a gated pass, \(context)")
                    strikes = out.missingOnce
                    streak = [:]
                    actingPassesSinceLeft = 0
                    continue
                }
                if pass >= leavesAt { actingPassesSinceLeft += 1 }
                for id in pinned {
                    streak[id] = (lookups[id] ?? nil) == false ? (streak[id] ?? 0) + 1 : 0
                    // Removed exactly when two real "gone" answers came in a row.
                    #expect(out.remove.contains(id) == ((streak[id] ?? 0) >= 2),
                            "id \(id) streak \(streak[id] ?? 0), \(context)")
                }
                strikes = out.missingOnce
                pinned.subtract(out.remove)
                if actingPassesSinceLeft >= 2 {
                    #expect(!pinned.contains(3), "window 3 is gone for good but still pinned, \(context)")
                }
            }
            #expect(pinned.contains(1), "window 1 never goes missing, seed \(seed)")
        }
    }
}

@Suite struct MenuOrderTests {
    private func pin(_ id: UInt32, pid: Int32, _ owner: String, _ title: String = "") -> PinnedWindow {
        PinnedWindow(windowID: id, ownerPID: pid, ownerName: owner, windowTitle: title)
    }

    @Test func frontAppFirstThenByName() {
        let pins = [pin(1, pid: 10, "Safari", "Docs"), pin(2, pid: 20, "Terminal", "build"),
                    pin(3, pid: 30, "Notes"), pin(4, pid: 20, "Terminal", "logs")]
        let order = PinPolicy.menuOrder(pins, frontPID: 20).map(\.windowID)
        #expect(order == [2, 4, 3, 1])
    }

    @Test func noFrontAppIsJustByName() {
        let pins = [pin(1, pid: 10, "safari"), pin(2, pid: 20, "Notes"), pin(3, pid: 30, "App 10"), pin(4, pid: 40, "App 9")]
        // Case-insensitive, with numbers in number order.
        #expect(PinPolicy.menuOrder(pins, frontPID: nil).map(\.windowID) == [4, 3, 2, 1])
    }

    @Test func sameNameKeepsAStableOrder() {
        let pins = [pin(7, pid: 10, "Notes"), pin(5, pid: 10, "Notes")]
        #expect(PinPolicy.menuOrder(pins, frontPID: nil).map(\.windowID) == [5, 7])
        #expect(PinPolicy.menuOrder(pins.reversed(), frontPID: nil).map(\.windowID) == [5, 7])
    }
}
