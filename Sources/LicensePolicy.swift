import Foundation

/// Where the download stands: in its trial, past it, or bought.
nonisolated enum LicenseState: Equatable, Sendable {
    case trial(daysLeft: Int)
    case expired
    case licensed

    /// How the menu and Settings name it.
    var label: String {
        switch self {
        case .licensed: "Licensed"
        case .expired: "Trial ended"
        case .trial(let days): days == 1 ? "Trial: 1 day left" : "Trial: \(days) days left"
        }
    }
}

/// A Polar key that has been activated on this Mac. The activation ID is
/// what Polar counts against the key's limit of Macs, and what deactivating
/// gives back.
nonisolated struct LicenseActivation: Codable, Equatable, Sendable {
    let key: String
    let activationID: String
}

/// Why a key was not accepted, worded for the person who typed it.
nonisolated enum LicenseError: Error, Equatable, Sendable {
    /// No such key.
    case notFound
    /// Polar's refusal: revoked, or already on as many Macs as it allows.
    case refused(String)
    /// A real key, but for another product.
    case wrongProduct
    /// No answer that could be read: offline, or a server error page.
    case unreadable

    var message: String {
        switch self {
        case .notFound: "That key wasn't found. Check it against your receipt."
        case .refused(let reason): reason
        case .wrongProduct: "This key is for a different product."
        case .unreadable: "Couldn't reach Polar. Check your connection and try again."
        }
    }
}

/// The decisions behind the trial and the licence, with time and the
/// server's answer passed in. The download builds call these; building from
/// source has no licence at all.
nonisolated enum LicensePolicy {
    static let trialDays = 14
    private static let day: TimeInterval = 86_400

    static func state(firstLaunch: Date, now: Date, activation: LicenseActivation?) -> LicenseState {
        if activation != nil { return .licensed }
        // A clock set back before the first launch counts as day one, not as
        // extra days.
        let elapsed = max(0, now.timeIntervalSince(firstLaunch))
        let left = trialDays - Int((elapsed / day).rounded(.down))
        return left > 0 ? .trial(daysLeft: left) : .expired
    }

    /// After the trial, no new perches until a key is entered. Windows
    /// already perched stay, and can always be unperched.
    static func allowsToggle(state: LicenseState, alreadyPerched: Bool) -> Bool {
        alreadyPerched || state != .expired
    }

    /// Whether `POST …/license-keys/deactivate` left this Mac uncounted.
    /// Polar answers 204 when it did, and 404 when it never knew this
    /// activation, which counts as done: the key can be forgotten here.
    static func deactivated(status: Int) -> Bool {
        status == 204 || status == 404
    }

    /// Reads the answer to `POST …/license-keys/activate`. The organisation
    /// and benefit are checked so that a key for another product, or a Polar
    /// response from somewhere unexpected, never unlocks Perch.
    static func activation(
        status: Int, data: Data, key: String, organizationID: String, benefitID: String
    ) -> Result<LicenseActivation, LicenseError> {
        switch status {
        case 200:
            guard let reply = try? JSONDecoder().decode(Activated.self, from: data) else {
                return .failure(.unreadable)
            }
            guard reply.licenseKey.organizationID == organizationID,
                  reply.licenseKey.benefitID == benefitID else { return .failure(.wrongProduct) }
            return .success(LicenseActivation(
                key: key.trimmingCharacters(in: .whitespacesAndNewlines), activationID: reply.id))
        case 404:
            return .failure(.notFound)
        case 403, 422:
            // Polar's wording for a refusal isn't documented, so the reason
            // shown is ours; the likely ones are a revoked key or one already
            // on every Mac it allows.
            return .failure(.refused(
                "This key can't be activated here. It may be in use on 5 Macs already: deactivate one in its Settings, or contact support."))
        default:
            return .failure(.unreadable)
        }
    }

    private struct Activated: Decodable {
        let id: String
        let licenseKey: Key
        enum CodingKeys: String, CodingKey { case id, licenseKey = "license_key" }

        struct Key: Decodable {
            let organizationID: String
            let benefitID: String
            enum CodingKeys: String, CodingKey {
                case organizationID = "organization_id"
                case benefitID = "benefit_id"
            }
        }
    }
}
