import CoreGraphics
import Testing
@testable import WindowPin

@Suite struct ScrollValueTests {

    @Test(arguments: [(3.0, 3.0), (-3.0, -3.0), (0.0, 0.0), (1.0, 1.0)] as [(Double, Double)])
    func preciseDeltaIsUsedAsIs(delta: Double, expected: Double) {
        #expect(ScrollMath.points(fromDelta: CGFloat(delta), precise: true) == CGFloat(expected))
    }

    @Test(arguments: [(1.0, 10.0), (-2.0, -20.0), (0.0, 0.0), (0.5, 5.0)] as [(Double, Double)])
    func wheelLinesBecomeTenPointsEach(delta: Double, expected: Double) {
        #expect(ScrollMath.points(fromDelta: CGFloat(delta), precise: false) == CGFloat(expected))
    }

    // (current, deltaPoints, sensitivity, expected)
    @Test(arguments: [
        (0.5, 100.0, 0.001, 0.4),      // content down: position goes up the bar (smaller)
        (0.5, -100.0, 0.001, 0.6),
        (0.0, 100.0, 0.001, nil),      // at top, pushing further up: nothing to write
        (1.0, -100.0, 0.001, nil),     // at bottom, pushing further down
        (0.0, -100.0, 0.001, 0.1),     // away from the top end
        (1.0, 100.0, 0.001, 0.9),
        (0.05, 1000.0, 0.001, 0.0),    // past the top clamps to 0
        (0.95, -1000.0, 0.001, 1.0),   // past the bottom clamps to 1
        (0.5, 1e9, 0.001, 0.0),        // huge
        (0.5, -1e9, 0.001, 1.0),
        (0.5, 0.0, 0.001, nil),        // zero delta
        (0.5, 0.005, 0.001, nil),      // below the minimum move (5e-6)
        (0.5, 0.05, 0.001, 0.49995),   // just above it (5e-5)
        (0.5, 100.0, 0.0, nil),        // zero sensitivity
    ] as [(Double, Double, Double, Double?)])
    func newValue(current: Double, delta: Double, sensitivity: Double, expected: Double?) {
        let got = ScrollMath.newValue(current: current, deltaPoints: delta, sensitivity: sensitivity)
        if let expected {
            #expect(got != nil)
            #expect(abs((got ?? -1) - expected) < 1e-9)
        } else {
            #expect(got == nil)
        }
    }

    @Test func resultStaysInRangeAndMovesTheRightWay() {
        var rng = SeededGenerator(seed: 7)
        for _ in 0..<5000 {
            let current = Double.random(in: 0...1, using: &rng)
            let delta = Double.random(in: -5000...5000, using: &rng)
            let sens = Double.random(in: 0.0001...0.01, using: &rng)
            guard let v = ScrollMath.newValue(current: current, deltaPoints: delta, sensitivity: sens) else { continue }
            #expect(v >= 0 && v <= 1)
            #expect(abs(v - current) > ScrollMath.minimumMove)
            // Positive delta never increases the value, negative never decreases it.
            #expect(delta > 0 ? v < current : v > current)
        }
    }

    @Test func repeatedScrollingConvergesToTheEndsAndStops() {
        var v = 0.5
        var writes = 0
        while let next = ScrollMath.newValue(current: v, deltaPoints: 50, sensitivity: 0.0015) {
            v = next
            writes += 1
            if writes > 1000 { break }
        }
        #expect(v == 0)
        #expect(writes <= 10)
    }
}

@Suite struct ScrollAreaChoiceTests {

    private let window = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let sidebar = CGRect(x: 0, y: 50, width: 200, height: 750)
    private let content = CGRect(x: 200, y: 50, width: 800, height: 750)
    private let nested = CGRect(x: 300, y: 100, width: 300, height: 200)

    @Test func noAreasMeansNoChoice() {
        #expect(ScrollMath.innermostIndex(of: [], containing: CGPoint(x: 5, y: 5)) == nil)
    }

    @Test(arguments: [
        (CGPoint(x: 100, y: 400), 0),   // sidebar, not the first-in-tree-wins trap
        (CGPoint(x: 700, y: 700), 1),   // content
        (CGPoint(x: 400, y: 150), 2),   // nested inside content: innermost wins
    ])
    func picksTheInnermostArea(point: CGPoint, expected: Int) {
        #expect(ScrollMath.innermostIndex(of: [sidebar, content, nested], containing: point) == expected)
    }

    @Test func orderInTheListDoesNotMatterForNesting() {
        let frames = [nested, content, sidebar]
        #expect(ScrollMath.innermostIndex(of: frames, containing: CGPoint(x: 400, y: 150)) == 0)
    }

    @Test(arguments: [
        CGPoint(x: 500, y: 10),      // toolbar above every area
        CGPoint(x: -1, y: 400),
        CGPoint(x: 2000, y: 2000),
    ])
    func outsideEveryAreaDoesNothing(point: CGPoint) {
        #expect(ScrollMath.innermostIndex(of: [sidebar, content, nested], containing: point) == nil)
    }

    @Test func equalAreasResolveToTheEarlier() {
        #expect(ScrollMath.innermostIndex(of: [content, content], containing: CGPoint(x: 500, y: 500)) == 0)
    }

    @Test func containsIsHalfOpen() {
        // CGRect.contains includes the min edge and excludes the max edge.
        let r = CGRect(x: 10, y: 10, width: 10, height: 10)
        #expect(ScrollMath.innermostIndex(of: [r], containing: CGPoint(x: 10, y: 10)) == 0)
        #expect(ScrollMath.innermostIndex(of: [r], containing: CGPoint(x: 20, y: 15)) == nil)
    }

    @Test func tinyAndEmptyAreas() {
        let tiny = CGRect(x: 100, y: 100, width: 1, height: 1)
        #expect(ScrollMath.innermostIndex(of: [window, tiny], containing: CGPoint(x: 100.5, y: 100.5)) == 1)
        // A zero-size rect contains nothing, so the enclosing area is chosen.
        let empty = CGRect(x: 100, y: 100, width: 0, height: 0)
        #expect(ScrollMath.innermostIndex(of: [window, empty], containing: CGPoint(x: 100, y: 100)) == 0)
    }

    @Test func chosenAreaAlwaysContainsThePointAndIsSmallest() {
        var rng = SeededGenerator(seed: 99)
        for _ in 0..<500 {
            let frames = (0..<Int.random(in: 0...8, using: &rng)).map { _ in
                CGRect(x: Double.random(in: 0...500, using: &rng), y: Double.random(in: 0...500, using: &rng),
                       width: Double.random(in: 0...500, using: &rng), height: Double.random(in: 0...500, using: &rng))
            }
            let p = CGPoint(x: Double.random(in: 0...1000, using: &rng), y: Double.random(in: 0...1000, using: &rng))
            let hits = frames.filter { $0.contains(p) }
            if let i = ScrollMath.innermostIndex(of: frames, containing: p) {
                #expect(frames[i].contains(p))
                #expect(hits.allSatisfy { $0.width * $0.height >= frames[i].width * frames[i].height })
            } else {
                #expect(hits.isEmpty)
            }
        }
    }
}

@Suite struct ScrollWalkLimitTests {

    @Test func theBudgetIsTheOneTheAppRelieson() {
        #expect(ScrollMath.nodeBudget == 400)
        #expect(ScrollMath.maxDepth == 12)
        #expect(ScrollMath.maxAreas == 8)
    }

    @Test(arguments: [
        (0, 0, 400, true), (11, 7, 1, true),
        (12, 0, 400, false),   // depth limit
        (0, 8, 400, false),    // enough areas found
        (0, 0, 0, false),      // budget spent
        (0, 0, -1, false),
    ] as [(Int, Int, Int, Bool)])
    func mayVisit(depth: Int, areas: Int, budget: Int, expected: Bool) {
        #expect(ScrollMath.mayVisit(depth: depth, areasFound: areas, budgetLeft: budget) == expected)
    }

    /// Simulates the walk over a synthetic tree to show the budget bounds the
    /// number of elements visited whatever the shape.
    @Test(arguments: [2, 5, 50])
    func aWalkNeverVisitsMoreThanTheBudget(fanout: Int) {
        var budget = ScrollMath.nodeBudget
        var visited = 0
        func walk(depth: Int) {
            guard ScrollMath.mayVisit(depth: depth, areasFound: 0, budgetLeft: budget) else { return }
            budget -= 1
            visited += 1
            for _ in 0..<fanout { walk(depth: depth + 1) }
        }
        walk(depth: 0)
        #expect(visited <= ScrollMath.nodeBudget)
    }
}

@Suite struct ScrollCacheTests {

    @Test(arguments: [
        (0.0, true), (4.99, true), (5.0, false), (5.01, false), (3600.0, false),
        (-1.0, true),
    ] as [(Double, Bool)])
    func freshnessByAge(age: Double, expected: Bool) {
        #expect(ScrollMath.cacheIsFresh(age: age) == expected)
    }
}

@Suite struct PendingScrollTests {

    private let p1 = CGPoint(x: 1, y: 1)
    private let p2 = CGPoint(x: 2, y: 2)

    @Test func firstDeltaSchedulesADrain() {
        let r = ScrollMath.accumulate(queued: nil, pid: 10, deltaY: 4, point: p1)
        #expect(r.scheduleDrain)
        #expect(r.pending == ScrollMath.Pending(pid: 10, deltaY: 4, point: p1))
    }

    @Test func laterDeltasAddUpAndTheNewestPointerWins() {
        var r = ScrollMath.accumulate(queued: nil, pid: 10, deltaY: 4, point: p1)
        r = ScrollMath.accumulate(queued: r.pending, pid: 10, deltaY: -1.5, point: p2)
        #expect(!r.scheduleDrain)
        #expect(r.pending == ScrollMath.Pending(pid: 10, deltaY: 2.5, point: p2))
    }

    @Test func opposingDeltasCancelButStayQueued() {
        var r = ScrollMath.accumulate(queued: nil, pid: 1, deltaY: 5, point: p1)
        r = ScrollMath.accumulate(queued: r.pending, pid: 1, deltaY: -5, point: p1)
        #expect(r.pending.deltaY == 0)
        #expect(!r.scheduleDrain)
    }

    @Test func aBurstSchedulesExactlyOneDrainAndLosesNothing() {
        var rng = SeededGenerator(seed: 3)
        var queued: ScrollMath.Pending?
        var drains = 0
        var total = 0.0
        for _ in 0..<1000 {
            let d = Double.random(in: -50...50, using: &rng)
            total += d
            let r = ScrollMath.accumulate(queued: queued, pid: 1, deltaY: CGFloat(d), point: p1)
            if r.scheduleDrain { drains += 1 }
            queued = r.pending
        }
        #expect(drains == 1)
        #expect(abs(Double(queued!.deltaY) - total) < 1e-6)
    }
}
