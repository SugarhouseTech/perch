import AppKit
import Testing
@testable import Perch

@Suite struct ScrollStepsTests {

    @Test(arguments: [
        (0.0, Int32(0)),
        (0.01, 1), (0.4, 1), (0.49, 1),     // sub-step ticks must not vanish
        (-0.01, -1), (-0.4, -1),
        (0.5, 1), (0.51, 1), (1.0, 1), (1.4, 1), (1.5, 2), (2.6, 3),
        (-0.5, -1), (-1.4, -1), (-1.5, -2), (-2.6, -3),
        (100.0, 100), (-100.0, -100),
        (1_000_000.0, 1_000_000), (-1_000_000.0, -1_000_000),
        (2_000_000_000.0, 2_000_000_000),
    ] as [(Double, Int32)])
    func roundsAndKeepsSign(delta: Double, expected: Int32) {
        #expect(EventMapping.scrollSteps(CGFloat(delta)) == expected)
    }

    @Test func negativeZeroIsZero() {
        #expect(EventMapping.scrollSteps(-0.0) == 0)
    }

    @Test func hugeAndNonFiniteDeltasDoNotTrap() {
        #expect(EventMapping.scrollSteps(1e12) == Int32.max)
        #expect(EventMapping.scrollSteps(-1e12) == Int32.min)
        #expect(EventMapping.scrollSteps(.infinity) == Int32.max)
        #expect(EventMapping.scrollSteps(-.infinity) == Int32.min)
        #expect(EventMapping.scrollSteps(.nan) == 0)
    }

    @Test func neverZeroForNonZeroAndSignMatches() {
        var rng = SeededGenerator(seed: 42)
        for _ in 0..<2000 {
            let d = Double.random(in: -5000...5000, using: &rng)
            let steps = EventMapping.scrollSteps(CGFloat(d))
            if d == 0 {
                #expect(steps == 0)
            } else {
                #expect(steps != 0)
                #expect((steps > 0) == (d > 0))
                #expect(abs(Double(steps) - d) <= 1)
            }
        }
    }
}

@Suite struct ModifierFlagsTests {

    private static let singles: [(NSEvent.ModifierFlags, CGEventFlags)] = [
        (.command, .maskCommand), (.control, .maskControl),
        (.option, .maskAlternate), (.shift, .maskShift),
    ]

    @Test func noModifiersGiveNoFlags() {
        #expect(EventMapping.cgFlags([]) == [])
    }

    // All 16 combinations of the four modifiers.
    @Test(arguments: 0..<16)
    func everyCombination(mask: Int) {
        var ns: NSEvent.ModifierFlags = []
        var expected: CGEventFlags = []
        for (i, pair) in Self.singles.enumerated() where mask & (1 << i) != 0 {
            ns.insert(pair.0)
            expected.insert(pair.1)
        }
        #expect(EventMapping.cgFlags(ns) == expected)
    }

    @Test(arguments: [NSEvent.ModifierFlags.capsLock, .function, .numericPad, .help])
    func otherModifiersAreDropped(extra: NSEvent.ModifierFlags) {
        #expect(EventMapping.cgFlags(extra) == [])
        #expect(EventMapping.cgFlags([extra, .command]) == .maskCommand)
    }
}

@Suite struct MouseTypeTests {

    @Test(arguments: [
        (NSEvent.EventType.leftMouseDown, CGEventType.leftMouseDown, CGMouseButton.left),
        (.leftMouseUp, .leftMouseUp, .left),
        (.leftMouseDragged, .leftMouseDragged, .left),
        (.rightMouseDown, .rightMouseDown, .right),
        (.rightMouseUp, .rightMouseUp, .right),
        (.rightMouseDragged, .rightMouseDragged, .right),
        (.otherMouseDown, .otherMouseDown, .center),
        (.otherMouseUp, .otherMouseUp, .center),
        (.otherMouseDragged, .otherMouseDragged, .center),
    ])
    func mapsButtonEvents(ns: NSEvent.EventType, cg: CGEventType, button: CGMouseButton) {
        let result = EventMapping.mouseType(for: ns)
        #expect(result?.0 == cg)
        #expect(result?.1 == button)
    }

    @Test(arguments: [
        NSEvent.EventType.scrollWheel, .mouseMoved, .mouseEntered, .mouseExited,
        .keyDown, .keyUp, .flagsChanged, .cursorUpdate, .magnify, .swipe, .rotate,
        .pressure, .tabletPoint,
    ])
    func nonButtonEventsAreNotMouseEvents(ns: NSEvent.EventType) {
        #expect(EventMapping.mouseType(for: ns) == nil)
    }

    @Test(arguments: [CGEventType.otherMouseDown, .otherMouseUp, .otherMouseDragged])
    func otherButtonsCarryTheirNumber(type: CGEventType) {
        #expect(EventMapping.carriesButtonNumber(type))
    }

    @Test(arguments: [
        CGEventType.leftMouseDown, .leftMouseUp, .leftMouseDragged,
        .rightMouseDown, .rightMouseUp, .rightMouseDragged, .mouseMoved, .scrollWheel,
    ])
    func leftAndRightDoNotCarryANumber(type: CGEventType) {
        #expect(!EventMapping.carriesButtonNumber(type))
    }
}

@Suite struct ClampTests {

    @Test(arguments: [
        NSEvent.EventType.leftMouseDragged, .leftMouseUp, .rightMouseDragged,
        .rightMouseUp, .otherMouseDragged, .otherMouseUp,
    ])
    func dragsAndReleasesClamp(type: NSEvent.EventType) {
        #expect(EventMapping.clampsToOverlay(type))
    }

    @Test(arguments: [
        NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown,
        .scrollWheel, .mouseMoved, .keyDown, .magnify,
    ])
    func pressesAndOthersDoNot(type: NSEvent.EventType) {
        #expect(!EventMapping.clampsToOverlay(type))
    }

    // Every release or drag that has a down counterpart is clamped, so a
    // button can never be left held in the target.
    @Test func everyButtonEventThatEndsOrContinuesAPressClamps() {
        let all: [NSEvent.EventType] = [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
        ]
        for t in all {
            let isDown = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(t)
            #expect(EventMapping.clampsToOverlay(t) == !isDown)
            #expect(EventMapping.mouseType(for: t) != nil)
        }
    }
}
