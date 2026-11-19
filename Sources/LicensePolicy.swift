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

/// A Lemon Squeezy key that has been activated on this Mac. The instance ID
/// is what Lemon Squeezy counts against the key's limit of Macs, and what
/// deactivating gives back.
nonisolated struct LicenseActivation: Codable, Equatable, Sendable {
    let key: String
    let instanceID: String
}

/// Why a key was not accepted, worded for the person who typed it.
nonisolated enum LicenseError: Error, Equatable, Sendable {
    /// Lemon Squeezy's own explanation: unknown key, disabled, too many Macs.
    case refused(String)
    /// A real key, but for another product or store.
    case wrongProduct
    /// No answer that could be read: offline, or a server error page.
    case unreadable

    var message: String {
        switch self {
        case .refused(let reason): reason
        case .wrongProduct: "This key is for a different product."
        case .unreadable: "Couldn't reach Lemon Squeezy. Check your connection and try again."
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

    /// Reads the answer to `POST /v1/licenses/deactivate`: whether this Mac
    /// is no longer counted against the key. Lemon Squeezy not knowing the
    /// Mac at all counts as done, so a key deactivated elsewhere can still
    /// be forgotten here.
    static func deactivated(from data: Data) -> Bool {
        guard let reply = try? JSONDecoder().decode(DeactivateReply.self, from: data) else { return false }
        return reply.deactivated || reply.error?.localizedCaseInsensitiveContains("not found") == true
    }

    private struct DeactivateReply: Decodable {
        let deactivated: Bool
        let error: String?
    }

    /// Reads the answer to `POST /v1/licenses/activate`. Lemon Squeezy says
    /// to check the store and product, since any key from any store would
    /// otherwise activate.
    static func activation(
        from data: Data, key: String, storeID: Int, productID: Int
    ) -> Result<LicenseActivation, LicenseError> {
        guard let reply = try? JSONDecoder().decode(ActivateReply.self, from: data) else {
            return .failure(.unreadable)
        }
        guard reply.activated, let instance = reply.instance else {
            return .failure(.refused(sentence(reply.error) ?? "This key wasn't accepted."))
        }
        guard reply.meta?.storeID == storeID, reply.meta?.productID == productID else {
            return .failure(.wrongProduct)
        }
        return .success(LicenseActivation(
            key: key.trimmingCharacters(in: .whitespacesAndNewlines), instanceID: instance.id))
    }

    /// Lemon Squeezy's errors are lower case and sometimes lack a full stop
    /// ("license_key not found."); shown as they come they look like a bug.
    private static func sentence(_ error: String?) -> String? {
        guard var text = error?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "license_key", with: "license key")
        text = text.prefix(1).uppercased() + text.dropFirst()
        return text.hasSuffix(".") ? text : text + "."
    }

    private struct ActivateReply: Decodable {
        let activated: Bool
        let error: String?
        let instance: Instance?
        let meta: Meta?

        struct Instance: Decodable { let id: String }
        struct Meta: Decodable {
            let storeID: Int
            let productID: Int
            enum CodingKeys: String, CodingKey {
                case storeID = "store_id"
                case productID = "product_id"
            }
        }
    }
}
