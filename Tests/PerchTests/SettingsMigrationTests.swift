import Foundation
import Testing
@testable import Perch

@Suite struct SettingsMigrationTests {
    @Test func copiesOldSettingsOnceWithoutOverwriting() throws {
        try withSuite { defaults in
            defaults.set(60.0, forKey: "captureRate")
            let old: [String: Any] = ["captureRate": 5.0, "pinToAllSpaces": true, "unpinBehavior": "hide"]
            let copied = SettingsMigration.run(old: old, into: defaults)
            #expect(copied == ["pinToAllSpaces", "unpinBehavior"])
            #expect(defaults.double(forKey: "captureRate") == 60)   // kept
            #expect(defaults.bool(forKey: "pinToAllSpaces"))
            // A second run copies nothing, even if the old settings change.
            #expect(SettingsMigration.run(old: ["badgeOffsets": ["x": 1]], into: defaults).isEmpty)
            #expect(defaults.object(forKey: "badgeOffsets") == nil)
        }
    }

    @Test func noOldSettingsStillOnlyRunsOnce() throws {
        try withSuite { defaults in
            #expect(SettingsMigration.run(old: nil, into: defaults).isEmpty)
            #expect(SettingsMigration.run(old: ["captureRate": 5.0], into: defaults).isEmpty)
        }
    }

    private func withSuite(_ body: (UserDefaults) throws -> Void) throws {
        let name = "SettingsMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }
}
