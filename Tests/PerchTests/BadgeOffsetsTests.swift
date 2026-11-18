import XCTest
@testable import Perch

final class BadgeOffsetsTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "BadgeOffsetsTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testBuiltInDistancesAreThereFromTheStart() {
        XCTAssertEqual(BadgeOffsets.all(in: defaults), BadgeOffsets.builtIn)
    }

    func testAnAppCanBeAddedChangedAndRemoved() {
        BadgeOffsets.set(120, for: "com.example.app", in: defaults)
        XCTAssertEqual(BadgeOffsets.all(in: defaults)["com.example.app"], 120)
        BadgeOffsets.set(60, for: "com.example.app", in: defaults)
        XCTAssertEqual(BadgeOffsets.all(in: defaults)["com.example.app"], 60)
        BadgeOffsets.remove("com.example.app", in: defaults)
        XCTAssertNil(BadgeOffsets.all(in: defaults)["com.example.app"])
    }

    func testABuiltInCanBeChangedRemovedAndAddedBack() {
        let id = "com.hnc.Discord"
        BadgeOffsets.set(100, for: id, in: defaults)
        XCTAssertEqual(BadgeOffsets.all(in: defaults)[id], 100)
        BadgeOffsets.remove(id, in: defaults)
        XCTAssertNil(BadgeOffsets.all(in: defaults)[id], "a removed built-in stays removed")
        BadgeOffsets.set(90, for: id, in: defaults)
        XCTAssertEqual(BadgeOffsets.all(in: defaults)[id], 90)
    }

    func testAStoredDistanceOutsideTheRangeIsPulledIn() {
        defaults.set(["a": 5_000.0, "b": -3.0], forKey: BadgeOffsets.key)
        let all = BadgeOffsets.all(in: defaults)
        XCTAssertEqual(all["a"], BadgeOffsets.range.upperBound)
        XCTAssertEqual(all["b"], BadgeOffsets.range.lowerBound)
    }

    func testTheButtonNeverLeavesTheWindow() {
        XCTAssertEqual(BadgeOffsets.clamped(84, width: 1000, side: 22), 84)
        XCTAssertEqual(BadgeOffsets.clamped(400, width: 300, side: 22), 300 - 22 - TitleBarSlot.margin)
        XCTAssertEqual(BadgeOffsets.clamped(400, width: 20, side: 22), TitleBarSlot.margin)
        XCTAssertEqual(BadgeOffsets.clamped(0, width: 1000, side: 22), TitleBarSlot.margin)
    }
}

final class BadgeOnlyWhenPinnedTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "BadgeOnlyWhenPinnedTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testAnAppCanShowItsButtonOnlyWhenPinned() {
        XCTAssertTrue(BadgeOffsets.onlyWhenPinned(in: defaults).isEmpty)
        BadgeOffsets.setOnlyWhenPinned(true, for: "a", in: defaults)
        BadgeOffsets.setOnlyWhenPinned(true, for: "a", in: defaults)
        XCTAssertEqual(BadgeOffsets.onlyWhenPinned(in: defaults), ["a"])
        BadgeOffsets.setOnlyWhenPinned(false, for: "a", in: defaults)
        XCTAssertTrue(BadgeOffsets.onlyWhenPinned(in: defaults).isEmpty)
    }

    func testRemovingAnAppShowsItsButtonAgain() {
        BadgeOffsets.set(50, for: "a", in: defaults)
        BadgeOffsets.setOnlyWhenPinned(true, for: "a", in: defaults)
        BadgeOffsets.remove("a", in: defaults)
        XCTAssertTrue(BadgeOffsets.onlyWhenPinned(in: defaults).isEmpty)
    }

    func testAnAddedAppStartsWhereTheButtonAlreadyIs() {
        XCTAssertEqual(BadgeOffsets.starting(for: "a", automatic: nil), BadgeOffsets.range.lowerBound)
        XCTAssertEqual(BadgeOffsets.starting(for: "a", automatic: 143.6), 144)
        XCTAssertEqual(BadgeOffsets.starting(for: "a", automatic: 9_000), BadgeOffsets.range.upperBound)
        XCTAssertEqual(BadgeOffsets.starting(for: "com.hnc.Discord", automatic: 10), BadgeOffsets.builtIn["com.hnc.Discord"])
    }
}

final class BadgeOffsetsStoreTests: XCTestCase {

    func testOneBadValueDoesNotLoseTheOthers() {
        let suite = "BadgeOffsetsStoreTests"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["a": 120, "b": "oops", "c": 60.5], forKey: BadgeOffsets.key)
        BadgeOffsets.set(70, for: "d", in: defaults)
        let all = BadgeOffsets.all(in: defaults)
        XCTAssertEqual(all["a"], 120)
        XCTAssertEqual(all["c"], 60.5)
        XCTAssertEqual(all["d"], 70)
        XCTAssertNil(all["b"])
    }
}
