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
            BadgeOffsets.setPauseApp(true, for: "com.example.app", in: defaults)
            #expect(BadgeOffsets.ignored(in: defaults) == ["com.example.app"])
            BadgeOffsets.remove("com.example.app", in: defaults)
            #expect(BadgeOffsets.ignored(in: defaults).isEmpty)
            #expect(BadgeOffsets.onlyWhenPinned(in: defaults).isEmpty)
            #expect(BadgeOffsets.pauseApps(in: defaults).isEmpty)
            #expect(BadgeOffsets.all(in: defaults)["com.example.app"] == nil)
        }
    }

    @Test func pausingAnAppIsIndependentAndRemovingItForgetsThat() throws {
        try withSuite { defaults in
            BadgeOffsets.setPauseApp(true, for: "game", in: defaults)
            BadgeOffsets.setPauseApp(true, for: "game", in: defaults)
            BadgeOffsets.setPauseApp(false, for: "unknown", in: defaults)
            #expect(BadgeOffsets.pauseApps(in: defaults) == ["game"])
        }
    }

    @Test(arguments: Array(0..<40).map(UInt64.init))
    func appPauseSettingsRemainIndependentThroughRandomEdits(seed: UInt64) throws {
        try withSuite { defaults in
            var rng = SeededGenerator(seed: seed)
            let apps = (0..<8).map { "app.\($0)" }
            var model = Set<String>()
            for _ in 0..<500 {
                let id = apps.randomElement(using: &rng)!
                switch Int.random(in: 0..<4, using: &rng) {
                case 0:
                    BadgeOffsets.setPauseApp(true, for: id, in: defaults)
                    model.insert(id)
                case 1:
                    BadgeOffsets.setPauseApp(false, for: id, in: defaults)
                    model.remove(id)
                case 2:
                    BadgeOffsets.setIgnored(true, for: id, in: defaults)
                default:
                    BadgeOffsets.setIgnored(false, for: id, in: defaults)
                }
                #expect(BadgeOffsets.pauseApps(in: defaults) == model, "seed \(seed)")
                #expect(BadgeOffsets.ignored(in: defaults).isSubset(of: Set(apps)), "seed \(seed)")

                if Int.random(in: 0..<20, using: &rng) == 0 {
                    BadgeOffsets.remove(id, in: defaults)
                    model.remove(id)
                    #expect(!BadgeOffsets.pauseApps(in: defaults).contains(id), "seed \(seed)")
                    #expect(!BadgeOffsets.ignored(in: defaults).contains(id), "seed \(seed)")
                }
            }
        }
    }

    @Test func switchingBetweenPausedAndUnpausedAppsDoesNotChangeStoredChoices() throws {
        try withSuite { defaults in
            BadgeOffsets.setPauseApp(true, for: "game", in: defaults)
            BadgeOffsets.setPauseApp(true, for: "editor", in: defaults)
            BadgeOffsets.setPauseApp(false, for: "chat", in: defaults)
            for frontmost in ["game", "chat", "editor", "game", "other"] {
                let shouldPause = BadgeOffsets.pauseApps(in: defaults).contains(frontmost)
                #expect(shouldPause == (frontmost == "game" || frontmost == "editor"))
            }
            #expect(BadgeOffsets.pauseApps(in: defaults) == ["game", "editor"])
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
