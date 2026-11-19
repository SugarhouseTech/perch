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

    /// The one menu row the download adds while unbought; none once bought.
    /// It opens the licence window, where buying and entering a key both are.
    var menuTitle: String? {
        switch self {
        case .licensed: nil
        case .expired: "Trial ended \u{00B7} Enter Key\u{2026}"
        case .trial(let days): "Buy Perch \u{00B7} \(days == 1 ? "1 day" : "\(days) days") left"
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
        // extra days. A start that isn't a real time (a hand-edited file)
        // counts as day one too, rather than trapping below.
        let raw = now.timeIntervalSince(firstLaunch)
        let elapsed = raw.isFinite ? min(max(0, raw), Double(trialDays + 1) * day) : 0
        let left = trialDays - Int((elapsed / day).rounded(.down))
        return left > 0 ? .trial(daysLeft: left) : .expired
    }

    /// After the trial, no new perches until a key is entered. Windows
    /// already perched stay, and can always be unperched.
    static func allowsToggle(state: LicenseState, alreadyPerched: Bool) -> Bool {
        alreadyPerched || state != .expired
    }

    /// What people paste is rarely just the key: a line from the receipt
    /// ("License key: PERCH-…"), quotes, a trailing newline, lower case
    /// from retyping it. Polar's keys are upper case and case-sensitive.
    static func normalizedKey(_ pasted: String) -> String {
        let quotes = CharacterSet(charactersIn: "\"'`\u{201C}\u{201D}\u{2018}\u{2019}")
        let token = pasted.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
        return token.trimmingCharacters(in: quotes).uppercased()
    }

    /// Whether `POST …/license-keys/deactivate` left this Mac uncounted.
    /// Polar answers 204 when it did, and 404 when it never knew this
    /// activation, which counts as done: the key can be forgotten here. A 422
    /// means the stored activation can't even be read by Polar, so keeping
    /// it would leave the Mac stuck; it is forgotten too.
    static func deactivated(status: Int) -> Bool {
        status == 204 || status == 404 || status == 422
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
        case 403:
            // Polar says "License key activation limit already reached" when
            // the key is on every Mac it allows; other refusals are a key
            // that was refunded or revoked.
            let detail = (try? JSONDecoder().decode(Refusal.self, from: data))?.detail ?? ""
            return .failure(.refused(detail.localizedCaseInsensitiveContains("activation limit")
                ? "This key is already on as many Macs as it allows. Deactivate it on one of them in Perch Settings, then try again."
                : "This key can't be activated. It may have been refunded. Contact support if that's a mistake."))
        case 422:
            return .failure(.refused("Polar couldn't read that key. Check it against your receipt."))
        default:
            return .failure(.unreadable)
        }
    }

    private struct Refusal: Decodable { let detail: String }

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
