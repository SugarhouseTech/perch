import XCTest
@testable import WindowPin

final class TitleBarSlotTests: XCTestCase {

    /// A title bar with controls over the given ranges, in points from the right edge.
    private func bar(_ taken: ClosedRange<CGFloat>...) -> (CGFloat) -> TitleBarSlot.Probe {
        { x in taken.contains { $0.contains(x) } ? .taken : .free }
    }

    func testEmptyTitleBarKeepsTheCorner() {
        XCTAssertEqual(TitleBarSlot.inset(side: 22, width: 800, probe: bar()), TitleBarSlot.margin)
    }

    func testBadgeMovesLeftOfAButtonInTheCorner() {
        // A 28pt button from 10pt to 38pt in from the edge.
        let inset = TitleBarSlot.inset(side: 22, width: 800, probe: bar(10...38))
        XCTAssertEqual(inset, 40)
    }

    func testBadgeFitsInAGapBetweenButtons() {
        // Buttons at 8–30 and 60–90: the gap 30–60 holds a 22pt badge.
        let inset = TitleBarSlot.inset(side: 22, width: 800, probe: bar(8...30, 60...90))
        XCTAssertEqual(inset, 32)
    }

    func testGapTooNarrowIsSkipped() {
        // A 14pt gap between 30 and 44 is too small.
        let inset = TitleBarSlot.inset(side: 22, width: 800, probe: bar(8...30, 44...70))
        XCTAssertEqual(inset, 72)
    }

    func testAToolbarFullOfButtonsFallsBackToTheCorner() {
        XCTAssertNil(TitleBarSlot.inset(side: 22, width: 300, probe: bar(0...300)))
    }

    func testAnAppThatDoesNotAnswerFallsBackToTheCorner() {
        XCTAssertNil(TitleBarSlot.inset(side: 22, width: 800) { _ in .failed })
    }

    func testNeverAsksTooManyTimes() {
        var asked = 0
        _ = TitleBarSlot.inset(side: 22, width: 4000) { _ in asked += 1; return .taken }
        XCTAssertLessThanOrEqual(asked, TitleBarSlot.maxProbes)
    }

    func testEachPointIsAskedOnce() {
        var asked: [CGFloat] = []
        _ = TitleBarSlot.inset(side: 22, width: 800) { x in
            asked.append(x)
            return (40...44).contains(x) ? .taken : .free
        }
        XCTAssertEqual(asked.count, Set(asked).count)
    }
}

final class BadgeSpotTests: XCTestCase {

    func testBadgeIsCentredOnTheCloseButton() {
        // A plain title bar: close button middle 14pt down.
        XCTAssertEqual(BadgeSpot.top(centredOn: 14, side: 22), 3)
        // A tall unified toolbar: middle 26pt down.
        XCTAssertEqual(BadgeSpot.top(centredOn: 26, side: 22), 15)
    }

    func testCloseButtonInAnOddPlaceKeepsTheCorner() {
        XCTAssertEqual(BadgeSpot.top(centredOn: 300, side: 22), BadgeSpot.corner.top)
        XCTAssertEqual(BadgeSpot.top(centredOn: -5, side: 22), BadgeSpot.corner.top)
        XCTAssertEqual(BadgeSpot.top(centredOn: .nan, side: 22), BadgeSpot.corner.top)
    }

}

/// When a remembered title-bar answer is asked again.
final class TitleBarRecheckTests: XCTestCase {

    typealias Finder = TitleBarSlotFinder
    private let size = CGSize(width: 800, height: 600)

    private func entry(sure: Bool, tries: Int = 1, at: TimeInterval = 100) -> Finder.Entry {
        Finder.Entry(size: size, spot: .corner, sure: sure, tries: tries, at: at)
    }

    func testANewWindowIsMeasured() {
        XCTAssertTrue(Finder.shouldMeasure(nil, now: 0, dragging: false))
    }

    func testASureAnswerIsKeptAtTheSameSize() {
        var e = entry(sure: true)
        e.see(size, at: 1000)
        XCTAssertFalse(Finder.shouldMeasure(e, now: 1000, dragging: false))
        XCTAssertFalse(Finder.wantsRecheck(e, now: 1000))
    }

    func testANewSizeIsMeasuredOnceItHoldsStill() {
        var e = entry(sure: true)
        e.see(CGSize(width: 900, height: 600), at: 200)
        XCTAssertFalse(Finder.shouldMeasure(e, now: 200.05, dragging: false))
        XCTAssertTrue(Finder.wantsRecheck(e, now: 200.05))
        XCTAssertTrue(Finder.shouldMeasure(e, now: 200.25, dragging: false))
        XCTAssertFalse(Finder.shouldMeasure(e, now: 200.25, dragging: true))
    }

    func testResizingBackToTheMeasuredSizeNeedsNoMeasurement() {
        var e = entry(sure: true)
        e.see(CGSize(width: 900, height: 600), at: 200)
        e.see(size, at: 200.1)
        XCTAssertFalse(Finder.shouldMeasure(e, now: 300, dragging: false))
        XCTAssertFalse(Finder.wantsRecheck(e, now: 300))
    }

    func testAWindowThatNeverStopsResizingIsLeftAlone() {
        var e = entry(sure: true, at: 100)
        var t: TimeInterval = 100
        while t < 110 {
            t += 1.0 / 60
            e.see(CGSize(width: 800 + (t * 60).truncatingRemainder(dividingBy: 50), height: 600), at: t)
            XCTAssertFalse(Finder.shouldMeasure(e, now: t, dragging: false))
        }
        XCTAssertFalse(Finder.wantsRecheck(e, now: t), "watching should stop after a few seconds")
    }

    func testAnAnswerThatSawNoControlIsAskedAgainAfterAWait() {
        // Electron's tree is empty on the first question and filled in a moment later.
        let first = entry(sure: false, tries: 1, at: 100)
        XCTAssertFalse(Finder.shouldMeasure(first, now: 100.1, dragging: false))
        XCTAssertTrue(Finder.shouldMeasure(first, now: 100.35, dragging: false))
        XCTAssertTrue(Finder.wantsRecheck(first, now: 100.1))
    }

    func testTheWaitGrowsAndThenGivesUp() {
        XCTAssertLessThan(Finder.recheckDelay(afterTries: 1), Finder.recheckDelay(afterTries: 2))
        let last = entry(sure: false, tries: Finder.maxTries, at: 100)
        XCTAssertFalse(Finder.shouldMeasure(last, now: 10_000, dragging: false))
        XCTAssertFalse(Finder.wantsRecheck(last, now: 100))
    }

    func testAnAppWithItsTreeBuiltIsBelievedAtOnce() {
        XCTAssertTrue(Finder.merge(found: [20, 40], failed: false, earlier: nil).sure)
        XCTAssertFalse(Finder.merge(found: [], failed: false, earlier: nil).sure)
        XCTAssertFalse(Finder.merge(found: [20], failed: true, earlier: nil).sure)
    }

    func testAHalfBuiltFlickeringTreeIsNeverForgotten() {
        // A freshly started Discord: nothing, only the help button, nothing
        // again, then help and inbox.
        var known: Set<Int> = []
        for found: Set<Int> in [[20, 40], [], [20, 40, 56, 76]] {
            let m = Finder.merge(found: found, failed: false, earlier: known)
            XCTAssertFalse(m.sure, "a late app is asked until its tries run out")
            XCTAssertEqual(m.grew, !found.isSubset(of: known))
            known = m.known
        }
        XCTAssertEqual(known, [20, 40, 56, 76])
        XCTAssertFalse(Finder.merge(found: [20, 40], failed: false, earlier: known).grew,
                       "a partial answer takes nothing away")
    }

    func testATreeStillGrowingGetsMoreTries() {
        let growing = Finder.Entry(size: size, spot: .corner, sure: false, grew: true,
                                   tries: Finder.maxTries, at: 100)
        XCTAssertTrue(Finder.shouldMeasure(growing, now: 110, dragging: false))
        let done = Finder.Entry(size: size, spot: .corner, sure: false, grew: true,
                                tries: Finder.maxTriesWhileGrowing, at: 100)
        XCTAssertFalse(Finder.shouldMeasure(done, now: 10_000, dragging: false))
        XCTAssertFalse(Finder.wantsRecheck(done, now: 100))
    }

    func testControlsFromEveryAnswerAreKeptClearOf() {
        // The scan, given what earlier answers found, skips past all of it.
        let known: Set<Int> = [20, 40, 56, 76]
        let inset = TitleBarSlot.inset(side: 22, width: 1327) { known.contains(Int($0)) ? .taken : .free }
        XCTAssertEqual(inset, 80)
    }

    /// Model check: drive the policy with random sizes, timings and answers,
    /// as the controller would, and bound how often an app is asked.
    func testRandomScheduleNeverAsksOftenOrForever() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            var e: Finder.Entry?
            var t: TimeInterval = 0
            var measures: [TimeInterval] = []
            var lastSize = CGSize(width: 800, height: 600)
            var recheckUntil: TimeInterval = 0
            while t < 60 {
                // Ticks: 10 Hz while following, otherwise sparse events.
                t += t < recheckUntil ? 0.1 : Double.random(in: 0.01...5, using: &rng)
                if Int.random(in: 0..<10, using: &rng) == 0 {
                    lastSize = CGSize(width: CGFloat(Int.random(in: 400...1600, using: &rng)), height: 600)
                }
                let dragging = Int.random(in: 0..<8, using: &rng) == 0
                e?.see(lastSize, at: t)
                if Finder.shouldMeasure(e, now: t, dragging: dragging) {
                    let tries = e.map { $0.size == lastSize ? $0.tries + 1 : 1 } ?? 1
                    let sure = Int.random(in: 0..<3, using: &rng) == 0
                    let grew = Bool.random(using: &rng)
                    e = Finder.Entry(size: lastSize, spot: .corner, sure: sure, grew: grew, tries: tries, at: t)
                    measures.append(t)
                    XCTAssertLessThanOrEqual(tries, Finder.maxTriesWhileGrowing)
                }
                if let e, Finder.wantsRecheck(e, now: t) { recheckUntil = t + 0.5 }
            }
            // Never two measurements closer than the settle time or first recheck delay.
            for (a, b) in zip(measures, measures.dropFirst()) {
                XCTAssertGreaterThanOrEqual(b - a, min(Finder.settle, Finder.recheckDelay(afterTries: 1)) - 1e-9)
            }
        }
    }
}
