import CoreGraphics
import Foundation

/// The decisions AXScroller makes, over plain numbers and rectangles instead of
/// AXUIElements, so they can be tested without a target app.
enum ScrollMath {

    /// A wheel reports lines, about one per notch, where a trackpad reports
    /// points, so a wheel crawled at a tenth of the speed. Ten points is the
    /// line AppKit's own scroll views use.
    static func points(fromDelta delta: CGFloat, precise: Bool) -> CGFloat {
        precise ? delta : delta * 10
    }

    /// Smallest change worth writing to the app. Below this the set would be a
    /// round trip that moves nothing visible.
    static let minimumMove = 0.000_01

    /// The scroll bar value after a scroll of `deltaPoints`, or nil when nothing
    /// should be written (no movement, or already at the end it is pushed
    /// against). Scrolling content down means moving the position up, hence the
    /// minus. The result is always within 0...1.
    static func newValue(current: Double, deltaPoints: Double, sensitivity: Double) -> Double? {
        let target = min(1.0, max(0.0, current - deltaPoints * sensitivity))
        return abs(target - current) > minimumMove ? target : nil
    }

    /// Index of the scroll area to drive for a pointer: the smallest area that
    /// contains it. Scroll areas nest, and the innermost one is what the user is
    /// pointing at; the outermost is usually the whole window. Nil when the
    /// pointer is outside every area (the toolbar, say), so nothing scrolls that
    /// the user is not pointing at. Equal areas resolve to the earlier one.
    static func innermostIndex(of frames: [CGRect], containing point: CGPoint) -> Int? {
        var best: Int?
        var bestArea = CGFloat.infinity
        for (i, frame) in frames.enumerated() where frame.contains(point) {
            let area = frame.width * frame.height
            if area < bestArea { best = i; bestArea = area }
        }
        return best
    }

    // MARK: - Tree walk limits

    /// How many AX elements one walk may ask about. A web page's tree runs to
    /// thousands of elements, and each one asked about is a round trip to an app
    /// that may be busy.
    static let nodeBudget = 400
    /// Depth-limited on purpose: a deep tree on a busy app is where 29-second
    /// walks came from elsewhere.
    static let maxDepth = 12
    static let maxAreas = 8

    /// Whether the walk may visit another element.
    static func mayVisit(depth: Int, areasFound: Int, budgetLeft: Int) -> Bool {
        depth < maxDepth && areasFound < maxAreas && budgetLeft > 0
    }

    // MARK: - Caching

    static let cacheTTL: TimeInterval = 5

    /// A resolved tree is reused while younger than the TTL. A clock that went
    /// backwards (negative age) counts as fresh, as it always did.
    static func cacheIsFresh(age: TimeInterval) -> Bool { age < cacheTTL }

    // MARK: - Pending deltas

    /// Scrolling not yet applied for one window.
    struct Pending: Equatable {
        let pid: pid_t
        let deltaY: CGFloat
        let point: CGPoint
    }

    /// Fold a new delta into whatever is queued. Deltas add up; the newest
    /// pointer position and pid win. A drain is needed only when nothing was
    /// queued, because a queued entry already has one scheduled.
    static func accumulate(queued: Pending?, pid: pid_t, deltaY: CGFloat,
                           point: CGPoint) -> (pending: Pending, scheduleDrain: Bool) {
        (Pending(pid: pid, deltaY: (queued?.deltaY ?? 0) + deltaY, point: point), queued == nil)
    }
}
