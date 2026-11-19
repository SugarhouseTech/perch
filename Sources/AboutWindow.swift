import AppKit
import SwiftUI

/// About Perch: who made it, which version this is, and the few places
/// someone opening it is usually looking for, all one click away.
enum AboutWindow {
    private static var window: NSWindow?

    static func show() {
        if let window {
            JorvikWindowHelper.showOnActiveSpace(window)
            window.makeFirstResponder(nil)
            return
        }
        let controller = NSHostingController(rootView: AboutView())
        let w = NSWindow(contentViewController: controller)
        w.title = "About Perch"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.setContentSize(controller.view.fittingSize)
        window = w
        JorvikWindowHelper.showOnActiveSpace(w)
        // AppKit would put keyboard focus, and a ring, on the first link.
        // Nothing here needs typing; Tab still reaches every link.
        w.makeFirstResponder(nil)
    }
}

private struct AboutView: View {
    static let website = URL(string: "https://sugarhouse.tech/products/perch/")!
    static let source = URL(string: "https://github.com/SugarhouseTech/perch")!
    static let windowPin = URL(string: "https://github.com/PerpetualBeta/WindowPin")!
    static let supportAddress = "support@sugarhouse.tech"

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "1.0"
        guard let build = info["CFBundleVersion"] as? String, build != short else { return short }
        return "\(short) (\(build))"
    }

    /// A support email that already says which Perch and which macOS, the
    /// first two questions any reply would ask.
    private var supportMail: URL {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.path = Self.supportAddress
        parts.queryItems = [URLQueryItem(
            name: "subject",
            value: "Perch \(version) on macOS \(os.majorVersion).\(os.minorVersion)")]
        return parts.url ?? URL(string: "mailto:\(Self.supportAddress)")!
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.bottom, 20)
            links
                .padding(.bottom, 22)
            thanks
                .padding(.bottom, 18)
            Text("Made with care in Salt Lake City by Sugarhouse Tech.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(width: 340)
        .textSelection(.enabled)
        // Escape closes it, as people expect of a small window like this.
        .background {
            Button("") { NSApp.keyWindow?.close() }
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 128, height: 128)
                .accessibilityHidden(true)
                .padding(.bottom, 4)
            Text("Perch")
                .font(.system(size: 26, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Keep any window in view.")
                .foregroundStyle(.secondary)
            Text(statusLine)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .padding(.top, 2)
        }
    }

    /// The version, and in the download whether it's bought or how much
    /// trial is left: the two things people check here before writing in.
    private var statusLine: String {
        #if PERCH_DIRECT
        return "Version \(version) \u{00B7} \(Licensing.shared.state.label)"
        #else
        return "Version \(version)"
        #endif
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: 10) {
            LinkRow(symbol: "globe", title: "sugarhouse.tech/products/perch") {
                NSWorkspace.shared.open(Self.website)
            }
            LinkRow(symbol: "envelope", title: Self.supportAddress) {
                NSWorkspace.shared.open(supportMail)
            }
            .contextMenu {
                Button("Copy Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.supportAddress, forType: .string)
                }
            }
            #if PERCH_DIRECT
            LinkRow(symbol: "key", title: "Your purchase and key") {
                Licensing.shared.openOrders()
            }
            #endif
            LinkRow(symbol: "chevron.left.forwardslash.chevron.right", title: "Source code") {
                NSWorkspace.shared.open(Self.source)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var thanks: some View {
        VStack(spacing: 6) {
            Text("With thanks")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text("Perch grew from WindowPin, by Jonathan Hollin of Jorvik Software, who shared it freely.\nThank you, Jonathan.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Button("WindowPin on GitHub") { NSWorkspace.shared.open(Self.windowPin) }
                .buttonStyle(.link)
                .font(.callout)
        }
    }
}

/// One line in the list of places to go: an icon and a link.
private struct LinkRow: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.link)
    }
}
