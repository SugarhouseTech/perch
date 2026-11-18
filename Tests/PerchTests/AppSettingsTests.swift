import Foundation
import Testing
@testable import Perch

@Suite struct AppSettingsTests {
    @Test(arguments: [
        (40.4, 40.0), (40.6, 41.0), (-5, BadgeOffsets.range.lowerBound), (0, BadgeOffsets.range.lowerBound),
        (9999, BadgeOffsets.range.upperBound), (Double.nan, BadgeOffsets.range.lowerBound),
        (Double.infinity, BadgeOffsets.range.lowerBound),
    ] as [(Double, Double)])
    func typedDistancesAreWholeAndInRange(typed: Double, kept: Double) {
        #expect(BadgeOffsets.validated(typed) == kept)
    }

    @Test func anAppCanBeIgnoredAndRemovingItForgetsThat() throws {
        try withSuite { defaults in
            BadgeOffsets.set(60, for: "com.example.app", in: defaults)
            BadgeOffsets.setIgnored(true, for: "com.example.app", in: defaults)
            BadgeOffsets.setOnlyWhenPinned(true, for: "com.example.app", in: defaults)
            #expect(BadgeOffsets.ignored(in: defaults) == ["com.example.app"])
            BadgeOffsets.remove("com.example.app", in: defaults)
            #expect(BadgeOffsets.ignored(in: defaults).isEmpty)
            #expect(BadgeOffsets.onlyWhenPinned(in: defaults).isEmpty)
            #expect(BadgeOffsets.all(in: defaults)["com.example.app"] == nil)
        }
    }

    @Test func ignoringTwiceOrUnignoringAnUnknownAppIsHarmless() throws {
        try withSuite { defaults in
            BadgeOffsets.setIgnored(true, for: "a", in: defaults)
            BadgeOffsets.setIgnored(true, for: "a", in: defaults)
            BadgeOffsets.setIgnored(false, for: "b", in: defaults)
            #expect(BadgeOffsets.ignored(in: defaults) == ["a"])
        }
    }

    private func withSuite(_ body: (UserDefaults) throws -> Void) throws {
        let name = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }
}
