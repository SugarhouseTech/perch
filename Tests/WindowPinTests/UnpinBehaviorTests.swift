import Foundation
import Testing
@testable import WindowPin

@Suite struct UnpinBehaviorTests {
    @Test(arguments: [nil, "not a behaviour", "leaveInView"])
    func anythingElseReadsAsBringingTheWindowForward(stored: String?) throws {
        try withSuite { defaults in
            defaults.set(stored, forKey: UnpinBehavior.key)
            #expect(UnpinBehavior.stored(in: defaults) == .focus)
        }
    }

    @Test(arguments: UnpinBehavior.allCases)
    func readsWhatSettingsStores(behavior: UnpinBehavior) throws {
        try withSuite { defaults in
            defaults.set(behavior.rawValue, forKey: UnpinBehavior.key)
            #expect(UnpinBehavior.stored(in: defaults) == behavior)
        }
    }

    private func withSuite(_ body: (UserDefaults) throws -> Void) throws {
        let name = "UnpinBehaviorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }
}
