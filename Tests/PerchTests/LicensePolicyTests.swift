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
        let activation = LicenseActivation(key: "K", activationID: "A")
        let later = start.addingTimeInterval(1000 * day)
        #expect(LicensePolicy.state(firstLaunch: start, now: later, activation: activation) == .licensed)
    }

    private static let org = "11111111-1111-4111-8111-111111111111"
    private static let benefit = "22222222-2222-4222-8222-222222222222"

    // Shaped like Polar's documented LicenseKeyActivationCreated.
    private func activated(org: String = org, benefit: String = benefit) -> Data {
        Data("""
        {"id": "act-1", "license_key_id": "lk-1", "label": "Perch 1a2b3c4d", "meta": {},
         "created_at": "2026-11-19T00:00:00Z", "modified_at": null,
         "license_key": {"id": "lk-1", "organization_id": "\(org)", "benefit_id": "\(benefit)",
                         "customer_id": "c-1", "key": "K", "display_key": "****-K", "status": "granted",
                         "limit_activations": 5, "usage": 0, "limit_usage": null, "validations": 0,
                         "last_validated_at": null, "expires_at": null}}
        """.utf8)
    }

    private func activate(_ status: Int, _ data: Data, key: String = "K") -> Result<LicenseActivation, LicenseError> {
        LicensePolicy.activation(status: status, data: data, key: key,
                                 organizationID: Self.org, benefitID: Self.benefit)
    }

    @Test func acceptsAKeyForThisProduct() {
        #expect(activate(200, activated(), key: "  K\n") == .success(LicenseActivation(key: "K", activationID: "act-1")))
    }

    @Test(arguments: [
        ("33333333-3333-4333-8333-333333333333", benefit),
        (org, "44444444-4444-4444-8444-444444444444"),
    ])
    func refusesAKeyForAnotherOrganisationOrBenefit(org: String, benefit: String) {
        #expect(activate(200, activated(org: org, benefit: benefit)) == .failure(.wrongProduct))
    }

    @Test func anUnknownKeyIsNotFound() {
        let body = Data(#"{"error": "ResourceNotFound", "detail": "License key not found"}"#.utf8)
        #expect(activate(404, body) == .failure(.notFound))
    }

    // Polar's exact answer when every Mac is used (seen live, 2026-11-19).
    @Test func aFullKeySaysToDeactivateAMac() {
        let body = Data(#"{"error": "NotPermitted", "detail": "License key activation limit already reached"}"#.utf8)
        guard case .failure(.refused(let reason)) = activate(403, body) else { Issue.record("expected a refusal"); return }
        #expect(reason.contains("Deactivate it on one of them"))
    }

    @Test func anotherRefusalSuggestsARefund() {
        let body = Data(#"{"error": "NotPermitted", "detail": "License key is revoked"}"#.utf8)
        guard case .failure(.refused(let reason)) = activate(403, body) else { Issue.record("expected a refusal"); return }
        #expect(reason.contains("refunded"))
    }

    @Test func aMalformedKeyIsNotCalledFull() {
        guard case .failure(.refused(let reason)) = activate(422, Data(#"{"detail": []}"#.utf8)) else {
            Issue.record("expected a refusal"); return
        }
        #expect(!reason.contains("Macs"))
    }

    @Test(arguments: [
        ("PERCH-6237E382-170D-4AA5-BF80-D853BDF27A55", "PERCH-6237E382-170D-4AA5-BF80-D853BDF27A55"),
        ("  perch-6237e382-170d-4aa5-bf80-d853bdf27a55\n", "PERCH-6237E382-170D-4AA5-BF80-D853BDF27A55"),
        ("\"PERCH-AB\"", "PERCH-AB"),
        ("\u{201C}PERCH-AB\u{201D}", "PERCH-AB"),
        ("License key: PERCH-AB", "PERCH-AB"),
        ("`PERCH-AB`", "PERCH-AB"),
        ("", ""),
        (" \n\t", ""),
    ])
    func normalisesWhatPeoplePaste(pasted: String, sent: String) {
        #expect(LicensePolicy.normalizedKey(pasted) == sent)
    }

    @Test(arguments: [Double.nan, -1e30, 1e30, Double.infinity])
    func aNonsenseStartNeverTraps(seconds: Double) {
        let state = LicensePolicy.state(firstLaunch: Date(timeIntervalSince1970: seconds),
                                        now: Date(timeIntervalSince1970: 1_800_000_000), activation: nil)
        #expect(state == .expired || state == .trial(daysLeft: 14))
    }

    @Test(arguments: [
        (200, ""), (200, "<html>502 Bad Gateway</html>"), (502, "<html>502</html>"), (0, ""),
    ])
    func anUnreadableAnswerSaysSo(status: Int, body: String) {
        #expect(activate(status, Data(body.utf8)) == .failure(.unreadable))
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
        (LicenseState.trial(daysLeft: 12), "Buy Perch \u{00B7} 12 days left"),
        (.trial(daysLeft: 1), "Buy Perch \u{00B7} 1 day left"),
        (.expired, "Trial ended \u{00B7} Enter Key\u{2026}"),
    ])
    func oneMenuRowUntilBought(state: LicenseState, title: String) {
        #expect(state.menuTitle == title)
    }

    @Test func noMenuRowOnceBought() {
        #expect(LicenseState.licensed.menuTitle == nil)
    }

    @Test(arguments: [(204, true), (404, true), (422, true), (500, false), (0, false)])
    func readsTheDeactivateAnswer(status: Int, gone: Bool) {
        #expect(LicensePolicy.deactivated(status: status) == gone)
    }
}
