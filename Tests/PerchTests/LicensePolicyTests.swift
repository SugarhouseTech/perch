import Foundation
import Testing
@testable import Perch

@Suite struct LicensePolicyTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    @Test(arguments: [
        (0.0, LicenseState.trial(daysLeft: 14)),
        (0.9, .trial(daysLeft: 14)),
        (1.0, .trial(daysLeft: 13)),
        (13.99, .trial(daysLeft: 1)),
        (14.0, .expired),
        (400.0, .expired),
        (-30.0, .trial(daysLeft: 14)),  // clock set back
    ])
    func trialCountsWholeDays(daysElapsed: Double, expected: LicenseState) {
        let now = start.addingTimeInterval(daysElapsed * day)
        #expect(LicensePolicy.state(firstLaunch: start, now: now, activation: nil) == expected)
    }

    @Test func anActivatedKeyOutlastsTheTrial() {
        let activation = LicenseActivation(key: "K", instanceID: "I")
        let later = start.addingTimeInterval(1000 * day)
        #expect(LicensePolicy.state(firstLaunch: start, now: later, activation: activation) == .licensed)
    }

    // Shaped like Lemon Squeezy's documented replies.
    private func reply(activated: Bool, error: String? = nil, store: Int = 7, product: Int = 42) -> Data {
        let instance = activated ? #"{"id": "inst-1", "name": "x", "created_at": "2026-11-19T00:00:00Z"}"# : "null"
        let errorJSON = error.map { "\"\($0)\"" } ?? "null"
        return Data("""
        {"activated": \(activated), "error": \(errorJSON),
         "license_key": {"id": 1, "status": "active", "key": "K", "activation_limit": 5, "activation_usage": 1},
         "instance": \(instance),
         "meta": {"store_id": \(store), "order_id": 2, "product_id": \(product), "product_name": "Perch",
                  "variant_id": 3, "customer_id": 4, "customer_name": "A", "customer_email": "a@example.com"}}
        """.utf8)
    }

    @Test func acceptsAKeyForThisProduct() {
        let result = LicensePolicy.activation(from: reply(activated: true), key: "  K\n", storeID: 7, productID: 42)
        #expect(result == .success(LicenseActivation(key: "K", instanceID: "inst-1")))
    }

    @Test(arguments: [(8, 42), (7, 41)])
    func refusesAKeyForAnotherStoreOrProduct(store: Int, product: Int) {
        let data = reply(activated: true, store: store, product: product)
        #expect(LicensePolicy.activation(from: data, key: "K", storeID: 7, productID: 42) == .failure(.wrongProduct))
    }

    @Test(arguments: [
        ("license_key not found.", "License key not found."),
        ("This license key has reached the activation limit", "This license key has reached the activation limit."),
    ])
    func passesOnLemonSqueezysReasonAsASentence(error: String, shown: String) {
        let data = reply(activated: false, error: error)
        #expect(LicensePolicy.activation(from: data, key: "K", storeID: 7, productID: 42) == .failure(.refused(shown)))
    }

    @Test(arguments: ["", "<html>502 Bad Gateway</html>", #"{"activated": "yes"}"#])
    func anUnreadableAnswerSaysSo(body: String) {
        #expect(LicensePolicy.activation(from: Data(body.utf8), key: "K", storeID: 7, productID: 42) == .failure(.unreadable))
    }
}

@Suite struct LicenseRulesTests {
    @Test(arguments: [
        (LicenseState.trial(daysLeft: 3), false, true),
        (.licensed, false, true),
        (.expired, false, false),  // no new perches after the trial
        (.expired, true, true),    // but unperching always works
    ])
    func whatTheTrialAllows(state: LicenseState, alreadyPerched: Bool, allowed: Bool) {
        #expect(LicensePolicy.allowsToggle(state: state, alreadyPerched: alreadyPerched) == allowed)
    }

    @Test(arguments: [
        (LicenseState.trial(daysLeft: 1), "Trial: 1 day left"),
        (.trial(daysLeft: 14), "Trial: 14 days left"),
        (.expired, "Trial ended"),
        (.licensed, "Licensed"),
    ])
    func labels(state: LicenseState, label: String) {
        #expect(state.label == label)
    }

    @Test(arguments: [
        (#"{"deactivated": true, "error": null}"#, true),
        (#"{"deactivated": false, "error": "license_key instance not found."}"#, true),
        (#"{"deactivated": false, "error": "license_key not valid."}"#, false),
        ("<html>502</html>", false),
    ])
    func readsTheDeactivateAnswer(body: String, gone: Bool) {
        #expect(LicensePolicy.deactivated(from: Data(body.utf8)) == gone)
    }
}
