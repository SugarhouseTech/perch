#if PERCH_DIRECT
import AppKit
import Combine
import Security
import SwiftUI

/// The trial and the Polar key, in the download from sugarhouse.tech only.
/// The decisions are in `LicensePolicy`; this keeps the state and talks to
/// Polar, once when a key is entered and once if it is deactivated. Nothing is checked online after that.
///
/// Building from source leaves all of this out, and Perch has no trial.
final class Licensing: ObservableObject {
    static let shared = Licensing()

    /// Set by the release build in Info.plist, so the store's details stay
    /// out of the source.
    private struct Store {
        let organizationID: String
        let benefitID: String
        let buyURL: URL
        let ordersURL: URL

        init?(_ info: [String: Any]) {
            guard let organizationID = info["PerchPolarOrganizationID"] as? String,
                  let benefitID = info["PerchPolarBenefitID"] as? String,
                  let buy = (info["PerchBuyURL"] as? String).flatMap(URL.init(string:)),
                  let orders = (info["PerchOrdersURL"] as? String).flatMap(URL.init(string:))
            else { return nil }
            (self.organizationID, self.benefitID, buyURL, ordersURL) = (organizationID, benefitID, buy, orders)
        }
    }

    private let store = Store(Bundle.main.infoDictionary ?? [:])
    private let firstLaunch: Date
    /// Read from the Keychain once; every menu opening asks for the state.
    @Published private(set) var activation: LicenseActivation?
    /// The Keychain couldn't be read (locked, or access refused) rather than
    /// having no licence in it. Until a read succeeds, Perch neither nags nor
    /// blocks: a buyer must never look unlicensed, and be tempted to spend
    /// another of the key's Macs, because of a Keychain hiccup.
    private var keychainUnreadable = false

    private init() {
        firstLaunch = Self.loadFirstLaunch()
        loadActivation()
    }

    private func loadActivation() {
        switch Keychain.read() {
        case .found(let stored): (activation, keychainUnreadable) = (stored, false)
        case .none: (activation, keychainUnreadable) = (nil, false)
        case .unreadable: keychainUnreadable = true
        }
    }

    var state: LicenseState {
        if keychainUnreadable { loadActivation() }
        if keychainUnreadable { return .licensed }
        return LicensePolicy.state(firstLaunch: firstLaunch, now: Date(), activation: activation)
    }

    func activate(key: String) async -> LicenseError? {
        guard let store else { return .unreadable }
        let key = LicensePolicy.normalizedKey(key)
        // Polar shows the label beside each Mac using a key. A random one, so
        // the Mac's own name never leaves it.
        let body = ["key": key, "organization_id": store.organizationID,
                    "label": "Perch \(UUID().uuidString.prefix(8))"]
        guard let (status, data) = await Self.post("activate", body) else { return .unreadable }
        switch LicensePolicy.activation(status: status, data: data, key: key,
                                        organizationID: store.organizationID, benefitID: store.benefitID) {
        case .success(let activation):
            guard Keychain.write(activation) else {
                // Without the Keychain entry this Mac would forget the key at
                // the next launch, and a second try would spend another of
                // its Macs. Give this one back.
                _ = await Self.post("deactivate", ["key": activation.key, "organization_id": store.organizationID,
                                                   "activation_id": activation.activationID])
                return .refused("Perch couldn't save the key in your Keychain. Unlock it in Keychain Access, then try again.")
            }
            self.activation = activation
            return nil
        case .failure(let error):
            return error
        }
    }

    /// Gives this Mac's place back to the key, so it can be used on another.
    /// The key is forgotten here only once Polar agrees, or says it never
    /// knew this Mac.
    func deactivate() async -> Bool {
        guard let activation, let store else { return true }
        let body = ["key": activation.key, "organization_id": store.organizationID,
                    "activation_id": activation.activationID]
        guard let (status, _) = await Self.post("deactivate", body) else { return false }
        let gone = LicensePolicy.deactivated(status: status)
        if gone {
            Keychain.delete()
            self.activation = nil
        }
        return gone
    }

    func openBuyPage() { if let url = store?.buyURL { NSWorkspace.shared.open(url) } }
    func openOrders() { if let url = store?.ordersURL { NSWorkspace.shared.open(url) } }

    // MARK: - Polar

    /// Polar's customer-portal licence endpoints need no token, so a desktop
    /// app can call them. The answer is in the status as much as the body.
    private static func post(_ action: String, _ fields: [String: String]) async -> (Int, Data)? {
        var request = URLRequest(url: URL(string: "https://api.polar.sh/v1/customer-portal/license-keys/\(action)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(fields)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch {
            wplog("license: \(action) failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Trial start

    /// A file, as in HotMic, not the Keychain: deleting it to restart the
    /// trial is allowed to work. A missing or unreadable file starts the
    /// trial again rather than locking anyone out.
    private static func loadFirstLaunch() -> Date {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Perch")
        let file = dir.appendingPathComponent("firstlaunch")
        if let text = try? String(contentsOf: file, encoding: .utf8),
           let seconds = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           seconds.isFinite, seconds > 0 {
            return Date(timeIntervalSince1970: seconds)
        }
        let now = Date()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? String(now.timeIntervalSince1970).write(to: file, atomically: true, encoding: .utf8)
        return now
    }

    // MARK: - Keychain

    /// The login keychain, which Migration Assistant and Time Machine carry
    /// to a new Mac.
    private enum Keychain {
        static let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "tech.sugarhouse.Perch",
            kSecAttrAccount as String: "license",
        ]

        enum Read { case found(LicenseActivation), none, unreadable }

        static func read() -> Read {
            var q = query
            q[kSecReturnData as String] = true
            var result: AnyObject?
            let status = SecItemCopyMatching(q as CFDictionary, &result)
            if status == errSecItemNotFound { return .none }
            guard status == errSecSuccess, let data = result as? Data else {
                wplog("license: keychain read failed (\(status))")
                return .unreadable
            }
            // An entry that can't be decoded is as good as none.
            return (try? JSONDecoder().decode(LicenseActivation.self, from: data)).map(Read.found) ?? .none
        }

        static func write(_ activation: LicenseActivation) -> Bool {
            guard let data = try? JSONEncoder().encode(activation) else { return false }
            delete()
            var q = query
            q[kSecValueData as String] = data
            let status = SecItemAdd(q as CFDictionary, nil)
            if status != errSecSuccess { wplog("license: keychain write failed (\(status))") }
            return status == errSecSuccess
        }

        static func delete() {
            SecItemDelete(query as CFDictionary)
        }
    }
}

// MARK: - Window

/// Where a key is entered, and where the trial ending sends the user.
enum LicenseWindow {
    private static var window: NSWindow?

    static func show() {
        if let window {
            JorvikWindowHelper.showOnActiveSpace(window, activate: true)
            return
        }
        let controller = NSHostingController(rootView: LicenseView { LicenseWindow.window?.close() })
        let w = NSWindow(contentViewController: controller)
        w.title = "Perch License"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.setContentSize(controller.view.fittingSize)
        window = w
        JorvikWindowHelper.showOnActiveSpace(w, activate: true)
    }
}

private struct LicenseView: View {
    let close: () -> Void
    @ObservedObject private var licensing = Licensing.shared
    @State private var key = ""
    @State private var error: String?
    @State private var working = false

    private func headline(_ state: LicenseState) -> String {
        switch state {
        case .licensed: "Thank you!"
        case .expired: "Your trial has ended"
        case .trial(let days): days == 1 ? "1 day left in your trial" : "\(days) days left in your trial"
        }
    }

    var body: some View {
        let state = licensing.state
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline(state))
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(state == .licensed
                         ? "Perch is all yours on this Mac."
                         : "Your key is in your receipt email.")
                        .foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)

            if state != .licensed {
                TextField("License key", text: $key)
                    .accessibilityLabel("License key")
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(activate)
                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Buy Perch") { licensing.openBuyPage() }
                    Button("Lost your key?") { licensing.openOrders() }
                        .buttonStyle(.link)
                    Spacer()
                    Button(working ? "Activating\u{2026}" : "Activate", action: activate)
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || LicensePolicy.normalizedKey(key).isEmpty)
                }
            } else {
                HStack {
                    Spacer()
                    Button("Done", action: close)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func activate() {
        // Return and the button both land here; a second request while the
        // first is out would spend a second Mac on the same key.
        guard !working, !LicensePolicy.normalizedKey(key).isEmpty else { return }
        working = true
        error = nil
        Task {
            error = await licensing.activate(key: key)?.message
            working = false
            // The answer appears away from the field VoiceOver is on.
            Announce.say(error ?? "Thank you! Perch is all yours on this Mac.")
        }
    }
}

// MARK: - Settings

/// The licence row in Settings: bought, or the trial and a way to buy.
struct LicenseSettingsSection: View {
    @ObservedObject private var licensing = Licensing.shared
    @State private var failed = false
    @State private var working = false

    var body: some View {
        let state = licensing.state
        Section("License") {
            // A plain row, not LabeledContent: that names its button after
            // the row, so VoiceOver read "Licensed, button" for Deactivate.
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.label)
                    if failed {
                        Text("Couldn't reach Polar. Try again when you're online.")
                            .font(.settingsHelp)
                    }
                }
                Spacer()
                if state == .licensed {
                    Button("Deactivate This Mac") {
                        guard !working else { return }
                        working = true
                        Task {
                            failed = !(await licensing.deactivate())
                            working = false
                        }
                    }
                    .disabled(working)
                } else {
                    Button("Enter Key\u{2026}") { LicenseWindow.show() }
                }
            }
        }
    }
}
#endif
