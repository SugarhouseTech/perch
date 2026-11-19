import CoreGraphics
import Testing
@testable import Perch

private typealias G = OverlayGeometry

private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: w, height: h)
}

@Suite struct CropClampingTests {

    static let window = CGSize(width: 800, height: 600)

    @Test(arguments: [
        // (crop, expected): inside stays, overhang is trimmed, a crop the
        // window has left entirely, or all but a sliver of, is kept as it was.
        (rect(10, 20, 100, 50), rect(10, 20, 100, 50)),
        (rect(750, 550, 100, 100), rect(750, 550, 50, 50)),
        (rect(-20, -10, 100, 100), rect(0, 0, 80, 90)),
        (rect(900, 700, 50, 50), rect(900, 700, 50, 50)),
        (rect(799.5, 10, 40, 40), rect(799.5, 10, 40, 40)),
    ])
    func clampedToTheWindow(crop: CGRect, expected: CGRect) {
        #expect(G.clampedCrop(crop, windowSize: Self.window) == expected)
    }

    @Test func noCropShowsTheWholeWindow() {
        #expect(G.clampedCrop(nil, windowSize: Self.window) == nil)
        #expect(G.shownRect(crop: nil, windowSize: Self.window) == CGRect(origin: .zero, size: Self.window))
    }
}

@Suite struct PanelToWindowTests {

    /// A window at (100, 50) in window-list coordinates, shown on a panel
    /// half its size.
    static let window = rect(100, 50, 800, 600)
    static let panel = CGSize(width: 400, height: 300)

    @Test(arguments: [
        // Panel points run up from the bottom; window-list points run down.
        (CGPoint(x: 0, y: 300), CGPoint(x: 100, y: 50)),     // panel top-left → window top-left
        (CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 650)),      // bottom-left
        (CGPoint(x: 400, y: 0), CGPoint(x: 900, y: 650)),    // bottom-right
        (CGPoint(x: 200, y: 150), CGPoint(x: 500, y: 350)),  // middle
    ])
    func wholeWindow(location: CGPoint, expected: CGPoint) {
        #expect(G.targetPoint(location: location, panelSize: Self.panel, window: Self.window,
                              crop: nil, clamped: false) == expected)
    }

    @Test func aCroppedPinMapsIntoItsCrop() {
        let crop = rect(200, 100, 200, 150)
        let topLeft = G.targetPoint(location: CGPoint(x: 0, y: 150), panelSize: CGSize(width: 200, height: 150),
                                    window: Self.window, crop: crop, clamped: false)
        #expect(topLeft == CGPoint(x: 300, y: 150))
        let middle = G.targetPoint(location: CGPoint(x: 100, y: 75), panelSize: CGSize(width: 200, height: 150),
                                   window: Self.window, crop: crop, clamped: false)
        #expect(middle == CGPoint(x: 400, y: 225))
    }

    @Test(arguments: [CGPoint(x: -1, y: 10), CGPoint(x: 401, y: 10), CGPoint(x: 10, y: -0.5), CGPoint(x: 10, y: 300.5)])
    func aPointOffThePanelHasNoMatch(location: CGPoint) {
        #expect(G.targetPoint(location: location, panelSize: Self.panel, window: Self.window,
                              crop: nil, clamped: false) == nil)
    }

    @Test func aReleaseOffThePanelGoesToTheNearestEdge() {
        let point = G.targetPoint(location: CGPoint(x: -50, y: 900), panelSize: Self.panel,
                                  window: Self.window, crop: nil, clamped: true)
        #expect(point == CGPoint(x: 100, y: 50))
    }

    @Test(arguments: [CGSize.zero, CGSize(width: 0, height: 10), CGSize(width: 10, height: 0)])
    func anEmptyPanelHasNoMatch(panel: CGSize) {
        #expect(G.targetPoint(location: .zero, panelSize: panel, window: Self.window,
                              crop: nil, clamped: true) == nil)
    }

    /// Every point on the panel lands on the part of the window it shows.
    @Test(arguments: 0..<20)
    func everyPointLandsInWhatIsShown(seed: Int) {
        var rng = SeededGenerator(seed: UInt64(seed))
        for _ in 0..<200 {
            let window = rect(.random(in: -2000...2000, using: &rng), .random(in: -1000...1000, using: &rng),
                              .random(in: 50...3000, using: &rng), .random(in: 50...2000, using: &rng))
            let crop: CGRect? = Bool.random(using: &rng) ? nil
                : rect(.random(in: -100...window.width, using: &rng), .random(in: -100...window.height, using: &rng),
                       .random(in: 1...800, using: &rng), .random(in: 1...800, using: &rng))
            let panel = CGSize(width: .random(in: 1...2000, using: &rng), height: .random(in: 1...2000, using: &rng))
            let location = CGPoint(x: .random(in: -100...panel.width + 100, using: &rng),
                                   y: .random(in: -100...panel.height + 100, using: &rng))
            let shown = G.shownRect(crop: crop, windowSize: window.size)
                .offsetBy(dx: window.minX, dy: window.minY).insetBy(dx: -1e-6, dy: -1e-6)
            let clamped = G.targetPoint(location: location, panelSize: panel, window: window, crop: crop, clamped: true)
            #expect(clamped.map(shown.contains) == true)
            if let free = G.targetPoint(location: location, panelSize: panel, window: window, crop: crop, clamped: false) {
                #expect(shown.contains(free))
                #expect(free == clamped)
            }
        }
    }
}

@Suite struct DrawingACropTests {

    static let panel = CGSize(width: 400, height: 300)

    @Test func aDragUpAndLeftIsTheSameRectangle() {
        let down = G.selectionRect(from: CGPoint(x: 50, y: 60), to: CGPoint(x: 150, y: 160), panelSize: Self.panel)
        let up = G.selectionRect(from: CGPoint(x: 150, y: 160), to: CGPoint(x: 50, y: 60), panelSize: Self.panel)
        #expect(down == rect(50, 60, 100, 100))
        #expect(up == down)
    }

    @Test func aDragPastThePanelStopsAtItsEdge() {
        let r = G.selectionRect(from: CGPoint(x: 350, y: 250), to: CGPoint(x: 900, y: 900), panelSize: Self.panel)
        #expect(r == rect(350, 250, 50, 50))
    }

    @Test func aDragWhollyOffThePanelSelectsNothing() {
        let r = G.selectionRect(from: CGPoint(x: 500, y: 500), to: CGPoint(x: 600, y: 600), panelSize: Self.panel)
        #expect(r.isNull)
        #expect(!G.isCrop(r, minimumSide: 16))
    }

    @Test(arguments: [
        (CGSize(width: 16, height: 16), true),
        (CGSize(width: 15.9, height: 100), false),
        (CGSize(width: 100, height: 15.9), false),
        (CGSize(width: 0, height: 0), false),
    ])
    func aTinySelectionIsAClick(size: CGSize, isCrop: Bool) {
        #expect(G.isCrop(CGRect(origin: .zero, size: size), minimumSide: 16) == isCrop)
    }

    @Test func theTopLeftOfThePanelIsTheTopLeftOfTheWindow() {
        // Panel at half scale. Its top-left quarter, in panel points from the
        // bottom, is the window's top-left quarter, from the top.
        let window = CGSize(width: 800, height: 600)
        let selection = rect(0, 150, 200, 150)
        #expect(G.crop(forSelection: selection, panelSize: Self.panel, windowSize: window, current: nil)
                == rect(0, 0, 400, 300))
    }

    @Test func croppingACroppedPinNarrowsIt() {
        let window = CGSize(width: 800, height: 600)
        let current = rect(100, 100, 200, 100)
        // The panel shows the crop at its own size; select its right half.
        let selection = rect(100, 0, 100, 100)
        let narrowed = G.crop(forSelection: selection, panelSize: CGSize(width: 200, height: 100),
                              windowSize: window, current: current)
        #expect(narrowed == rect(200, 100, 100, 100))
    }

    /// Selecting the whole panel asks for exactly what is shown, which for a
    /// crop hanging off the window is the part still on it.
    @Test(arguments: 0..<10)
    func theWholePanelIsWhatIsShown(seed: Int) {
        var rng = SeededGenerator(seed: UInt64(seed))
        for _ in 0..<200 {
            let window = CGSize(width: CGFloat(Int.random(in: 100...3000, using: &rng)),
                                height: CGFloat(Int.random(in: 100...2000, using: &rng)))
            let current = rect(CGFloat(Int.random(in: 0...50, using: &rng)), CGFloat(Int.random(in: 0...50, using: &rng)),
                               CGFloat(Int.random(in: 20...90, using: &rng)), CGFloat(Int.random(in: 20...90, using: &rng)))
            let panel = CGSize(width: CGFloat(Int.random(in: 20...1000, using: &rng)),
                               height: CGFloat(Int.random(in: 20...1000, using: &rng)))
            let whole = CGRect(origin: .zero, size: panel)
            #expect(G.crop(forSelection: whole, panelSize: panel, windowSize: window, current: current)
                    == G.shownRect(crop: current, windowSize: window))
        }
    }
}

@Suite struct ResizingACropTests {

    static let window = CGSize(width: 800, height: 600)
    /// A crop of (100, 100) 200x100 in window points, shown on a panel at the
    /// same size at screen (500, 400).
    static let crop = rect(100, 100, 200, 100)
    static let panel = rect(500, 400, 200, 100)

    @Test func nothingToDoWithoutAChange() {
        #expect(G.resizedCrop(Self.crop, from: Self.panel, to: Self.panel, windowSize: Self.window) == nil)
        #expect(G.resizedCrop(Self.crop, from: .zero, to: Self.panel, windowSize: Self.window) == nil)
    }

    @Test(arguments: [
        // (new panel, expected crop): each edge moves the crop's same edge.
        (rect(500, 400, 230, 100), rect(100, 100, 230, 100)),  // right edge out
        (rect(480, 400, 220, 100), rect(80, 100, 220, 100)),   // left edge out
        (rect(500, 400, 200, 130), rect(100, 70, 200, 130)),   // top edge up: crop's top moves up the window
        (rect(500, 370, 200, 130), rect(100, 100, 200, 130)),  // bottom edge down
        (rect(520, 420, 160, 60), rect(120, 120, 160, 60)),    // shrunk from every side
    ])
    func edgesMoveTheSameEdges(new: CGRect, expected: CGRect) {
        let result = G.resizedCrop(Self.crop, from: Self.panel, to: new, windowSize: Self.window)
        #expect(result?.crop == expected)
        #expect(result?.panel == new)
    }

    @Test func growingPastTheWindowIsTrimmedFromThatEdge() {
        // Left edge dragged 150 points out: the crop can only go 100.
        let result = G.resizedCrop(Self.crop, from: Self.panel, to: rect(350, 400, 350, 100), windowSize: Self.window)
        #expect(result?.crop == rect(0, 100, 300, 100))
        #expect(result?.panel == rect(400, 400, 300, 100))
    }

    @Test func aResizeThatOnlyTouchesTheWindowKeepsTheCrop() {
        // Dragged so the proposed crop starts exactly at the window's right edge.
        let result = G.resizedCrop(rect(700, 100, 100, 100), from: rect(0, 0, 100, 100), to: rect(100, 0, 100, 100),
                                   windowSize: Self.window)
        #expect(result?.crop == rect(700, 100, 100, 100))
    }

    @Test func roundingGoesToTheNearestPointNotOutwards() {
        #expect(G.roundedToPoints(rect(17, 46, 40.000000001, 27)) == rect(17, 46, 40, 27))
        #expect(G.roundedToPoints(rect(9.6, 0.4, 10, 10)) == rect(10, 0, 10, 10))
    }

    @Test func growingPastTheTopIsTrimmedFromTheTop() {
        let result = G.resizedCrop(Self.crop, from: Self.panel, to: rect(500, 400, 200, 250), windowSize: Self.window)
        #expect(result?.crop == rect(100, 0, 200, 200))
        #expect(result?.panel == rect(500, 400, 200, 200))
    }

    /// Whatever the resize, the crop stays on the window, the panel is the
    /// crop's size, and a resize that fits is taken exactly.
    @Test(arguments: 0..<20)
    func resizesStayOnTheWindow(seed: Int) {
        var rng = SeededGenerator(seed: UInt64(seed))
        for _ in 0..<300 {
            let window = CGSize(width: CGFloat(Int.random(in: 100...3000, using: &rng)),
                                height: CGFloat(Int.random(in: 100...2000, using: &rng)))
            let w = CGFloat(Int.random(in: 16...Int(window.width), using: &rng))
            let h = CGFloat(Int.random(in: 16...Int(window.height), using: &rng))
            let crop = rect(CGFloat(Int.random(in: 0...Int(window.width - w), using: &rng)),
                            CGFloat(Int.random(in: 0...Int(window.height - h), using: &rng)), w, h)
            let old = rect(CGFloat(Int.random(in: -500...3000, using: &rng)),
                           CGFloat(Int.random(in: -500...2000, using: &rng)), w, h)
            let dl = CGFloat(Int.random(in: -400...400, using: &rng)), dr = CGFloat(Int.random(in: -400...400, using: &rng))
            let db = CGFloat(Int.random(in: -400...400, using: &rng)), dt = CGFloat(Int.random(in: -400...400, using: &rng))
            let new = rect(old.minX - dl, old.minY - db, max(old.width + dl + dr, 16), max(old.height + db + dt, 16))
            guard let result = G.resizedCrop(crop, from: old, to: new, windowSize: window) else {
                #expect(old == new)
                continue
            }
            let windowRect = CGRect(origin: .zero, size: window)
            let proposed = rect(crop.minX + (new.minX - old.minX), crop.minY + (old.maxY - new.maxY),
                                new.width, new.height)
            let kept = proposed.intersection(windowRect)
            if kept.isNull || kept.width < 1 || kept.height < 1 {
                #expect(result.crop == crop, "a resize off the window keeps the crop")
            } else {
                #expect(windowRect.contains(result.crop))
                #expect(result.crop.width >= 1 && result.crop.height >= 1)
            }
            #expect(result.panel.size == result.crop.size)
            if windowRect.contains(proposed) {
                #expect(result.crop == proposed)
                #expect(result.panel == new)
            }
        }
    }
}

@Suite struct PanelPlacementTests {

    static let target = rect(100, 200, 800, 600)

    @Test func aWholePerchCoversTheWindow() {
        #expect(G.panelFrame(target: Self.target, crop: nil, movedOrigin: nil) == Self.target)
    }

    @Test func aCroppedPinSitsOverItsArea() {
        // Window points from the top; screen points from the bottom.
        let frame = G.panelFrame(target: Self.target, crop: rect(50, 100, 200, 150), movedOrigin: nil)
        #expect(frame == rect(150, 550, 200, 150))
    }

    @Test func aMovedPinStaysWhereItWasPut() {
        let frame = G.panelFrame(target: Self.target, crop: rect(50, 100, 200, 150), movedOrigin: CGPoint(x: 5, y: 6))
        #expect(frame == rect(5, 6, 200, 150))
    }

    @Test func aMovedPinShrinksWithAWindowThatShrinksPastIt() {
        let small = rect(100, 200, 150, 600)
        let frame = G.panelFrame(target: small, crop: rect(50, 100, 200, 150), movedOrigin: CGPoint(x: 5, y: 6))
        #expect(frame.size == CGSize(width: 100, height: 150))
    }

    @Test(arguments: [
        // (window-list bounds, primary height, AppKit frame)
        (rect(0, 0, 100, 50), CGFloat(1000), rect(0, 950, 100, 50)),        // top of the primary display
        (rect(10, 950, 100, 50), CGFloat(1000), rect(10, 0, 100, 50)),      // bottom of it
        (rect(0, -400, 100, 50), CGFloat(1000), rect(0, 1350, 100, 50)),    // a display above the primary
        (rect(-1920, 100, 300, 200), CGFloat(1080), rect(-1920, 780, 300, 200)), // a display to the left
    ])
    func windowListFramesFlipToAppKit(bounds: CGRect, primaryHeight: CGFloat, expected: CGRect) {
        #expect(G.appKitFrame(fromWindowList: bounds, primaryHeight: primaryHeight) == expected)
    }

    @Test func missingBoundsKeysAreZero() {
        #expect(G.bounds(fromWindowList: ["X": 5, "Width": 10]) == rect(5, 0, 10, 0))
        #expect(G.bounds(fromWindowList: [:]) == .zero)
    }
}

@Suite struct StreamSizingTests {

    @Test func theStreamFilmsTheShownAreaAtThePanelsSize() {
        let g = G.streamGeometry(crop: rect(30, 40, 100, 100), windowSize: CGSize(width: 800, height: 600),
                                 panelSize: CGSize(width: 100, height: 100))
        #expect(g == rect(30, 40, 100, 100))
        let whole = G.streamGeometry(crop: nil, windowSize: CGSize(width: 800, height: 600),
                                     panelSize: CGSize(width: 400, height: 300))
        #expect(whole == rect(0, 0, 400, 300))
    }

    @Test(arguments: [
        (CGSize(width: 400, height: 300), CGFloat(2), 800, 600),
        (CGSize(width: 400.6, height: 300.4), CGFloat(1), 400, 300),
        (CGSize(width: 0, height: 0), CGFloat(2), 1, 1),
        (CGSize(width: 0.2, height: 0.2), CGFloat(2), 1, 1),
    ])
    func outputPixels(panel: CGSize, scale: CGFloat, width: Int, height: Int) {
        let pixels = G.outputPixels(panelSize: panel, scale: scale)
        #expect(pixels.width == width)
        #expect(pixels.height == height)
    }

    @Test(arguments: [
        (1000, 6000, 5),        // exactly at the line
        (1001, 6000, 3),
        (5120 * 2, 2880 * 2, 3), // a 5K window at 2x
        (1600, 1000, 5),
        (1, 1, 5),
    ])
    func largeWindowsKeepFewerFramesInFlight(width: Int, height: Int, depth: Int) {
        #expect(G.queueDepth(width: width, height: height) == depth)
    }

    static let displays: [(frame: CGRect, scale: CGFloat)] = [
        (rect(0, 0, 1512, 982), 2),
        (rect(1512, 0, 2560, 1440), 1),
    ]

    @Test(arguments: [
        (rect(100, 100, 400, 300), CGFloat?(2)),
        (rect(1600, 100, 400, 300), CGFloat?(1)),
        (rect(1400, 100, 400, 300), CGFloat?(1)),  // straddling: the larger share wins
        (rect(1312, 100, 300, 300), CGFloat?(2)),
        (rect(9000, 9000, 10, 10), CGFloat?.none),
    ])
    func theDisplayHoldingMostOfTheWindowDecides(window: CGRect, scale: CGFloat?) {
        #expect(G.scale(under: window, displays: Self.displays) == scale)
    }

    @Test func noDisplaysNoScale() {
        #expect(G.scale(under: rect(0, 0, 10, 10), displays: []) == nil)
    }
}

@Suite struct FrameOnShowTests {

    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    @Test func theSameAreaShowsTheWholeFrame() {
        let old = rect(0, 0, 800, 600)
        #expect(G.contentsRect(current: Self.unit, from: old, to: old) == Self.unit)
    }

    @Test func aCropShowsItsPartOfTheFrame() {
        // The top-left quarter of the window, in window points from the top,
        // is the top-left quarter of the frame: from the bottom, y 0.5.
        let r = G.contentsRect(current: Self.unit, from: rect(0, 0, 800, 600), to: rect(0, 0, 400, 300))
        #expect(r == rect(0, 0.5, 0.5, 0.5))
    }

    @Test func aCropOfACropComposes() {
        let first = G.contentsRect(current: Self.unit, from: rect(0, 0, 800, 600), to: rect(400, 0, 400, 300))!
        let second = G.contentsRect(current: first, from: rect(400, 0, 400, 300), to: rect(600, 150, 200, 150))
        #expect(second == rect(0.75, 0.5, 0.25, 0.25))
    }

    @Test(arguments: [
        (rect(0, 0, 400, 300), rect(0, 0, 800, 600)),   // clearing a crop: more than the frame holds
        (rect(0, 0, 0, 300), rect(0, 0, 0, 300)),       // no old area
        (rect(0, 0, 400, 300), rect(350, 250, 100, 100)), // partly outside
    ])
    func anAreaTheFrameDoesNotHoldShowsNothing(old: CGRect, new: CGRect) {
        #expect(G.contentsRect(current: Self.unit, from: old, to: new) == nil)
    }
}

@Suite struct MovingACroppedPinTests {

    @Test(arguments: [
        (CGFloat(0), CGFloat(0), false),
        (CGFloat(2), CGFloat(2), false),
        (CGFloat(3), CGFloat(0), true),
        (CGFloat(0), CGFloat(-3), true),
        (CGFloat(2.2), CGFloat(2.2), true),
    ])
    func aPressIsAMoveOnceItTravels(dx: CGFloat, dy: CGFloat, isMove: Bool) {
        #expect(G.isMove(dx: dx, dy: dy, threshold: 3) == isMove)
    }
}

@Suite struct RestoredCropGeometryProperties {

    /// Rebuilding a paused pin from its saved crop must preserve what the
    /// user selected, independently of where the real window later moved.
    @Test(arguments: 0..<40)
    func savedCropKeepsItsWindowMappingAfterMove(seed: Int) {
        var rng = SeededGenerator(seed: UInt64(seed))
        for _ in 0..<250 {
            let width = CGFloat(Int.random(in: 100...2400, using: &rng))
            let height = CGFloat(Int.random(in: 100...1600, using: &rng))
            let cropWidth = CGFloat(Int.random(in: 16...Int(width), using: &rng))
            let cropHeight = CGFloat(Int.random(in: 16...Int(height), using: &rng))
            let crop = rect(
                CGFloat(Int.random(in: 0...Int(width - cropWidth), using: &rng)),
                CGFloat(Int.random(in: 0...Int(height - cropHeight), using: &rng)),
                cropWidth,
                cropHeight
            )
            let target = rect(
                CGFloat(Int.random(in: -3000...3000, using: &rng)),
                CGFloat(Int.random(in: -2000...2000, using: &rng)),
                width,
                height
            )
            let panelSize = crop.size
            let panelFrame = G.panelFrame(target: target, crop: crop, movedOrigin: nil)
            #expect(panelFrame.size == panelSize)

            let x = CGFloat.random(in: 0...panelSize.width, using: &rng)
            let y = CGFloat.random(in: 0...panelSize.height, using: &rng)
            let mapped = G.targetPoint(
                location: CGPoint(x: x, y: y),
                panelSize: panelSize,
                window: target,
                crop: crop,
                clamped: false
            )
            let expected = CGPoint(x: target.minX + crop.minX + x,
                                    y: target.minY + crop.minY + panelSize.height - y)
            #expect(mapped.map { abs($0.x - expected.x) <= 1e-9
                                && abs($0.y - expected.y) <= 1e-9 } == true)
        }
    }

    /// A crop clipped by a window resize keeps a nonempty panel and maps only
    /// points inside the surviving part of the real window.
    @Test(arguments: 0..<30)
    func savedCropClippedByResizeRemainsUsable(seed: Int) {
        var rng = SeededGenerator(seed: UInt64(seed))
        for _ in 0..<250 {
            let oldWidth = CGFloat(Int.random(in: 100...2000, using: &rng))
            let oldHeight = CGFloat(Int.random(in: 100...1200, using: &rng))
            let cropWidth = CGFloat(Int.random(in: 16...Int(oldWidth), using: &rng))
            let cropHeight = CGFloat(Int.random(in: 16...Int(oldHeight), using: &rng))
            let crop = rect(
                CGFloat(Int.random(in: 0...Int(oldWidth - cropWidth), using: &rng)),
                CGFloat(Int.random(in: 0...Int(oldHeight - cropHeight), using: &rng)),
                cropWidth,
                cropHeight
            )
            let newWindow = CGSize(width: CGFloat(Int.random(in: 1...Int(oldWidth), using: &rng)),
                                   height: CGFloat(Int.random(in: 1...Int(oldHeight), using: &rng)))
            let shown = G.shownRect(crop: crop, windowSize: newWindow)
            #expect(shown.width >= 1)
            #expect(shown.height >= 1)
            #expect(shown == crop || CGRect(origin: .zero, size: newWindow).contains(shown))
            let panel = G.panelFrame(target: rect(0, 0, newWindow.width, newWindow.height),
                                     crop: crop, movedOrigin: nil)
            #expect(panel.size == shown.size)
        }
    }

    @Test func movedSavedCropRetainsItsUserChosenOrigin() {
        let crop = rect(40, 75, 180, 120)
        let origin = CGPoint(x: -900, y: 1440)
        let target = rect(300, 200, 900, 700)
        #expect(G.panelFrame(target: target, crop: crop, movedOrigin: origin)
                == CGRect(origin: origin, size: crop.size))
    }
}
