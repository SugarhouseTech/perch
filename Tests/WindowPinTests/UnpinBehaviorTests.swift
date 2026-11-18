import Foundation
import Testing
@testable import WindowPin

@Suite struct UnpinBehaviorTests {
    @Test(arguments: [
        (UnpinBehavior.focus, true, UnpinBehavior.Action.focusThenHide),
        (.focus, false, .focusThenHide),
        (.leaveInView, true, .standIn),
        (.leaveInView, false, .hide),
        (.hide, true, .hide),
        (.hide, false, .hide),
    ])
    func action(behavior: UnpinBehavior, pinShowing: Bool, expected: UnpinBehavior.Action) {
        #expect(behavior.action(pinShowing: pinShowing) == expected)
    }

    @Test func defaultsToBringingTheWindowForward() throws {
        try withSuite { defaults in
            #expect(UnpinBehavior.stored(in: defaults) == .focus)
            defaults.set("not a behaviour", forKey: UnpinBehavior.key)
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
