import SwiftUI

struct JorvikAboutView: View {
    let appName: String

    static let sourceURL = URL(string: "https://github.com/SugarhouseTech/perch")!
    static let originalURL = URL(string: "https://github.com/PerpetualBeta/WindowPin")!

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 12) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 64, height: 64)
            }

            Text(appName)
                .font(.title2)
                .fontWeight(.semibold)

            Text("Version \(version)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
                .padding(.horizontal, 40)

            VStack(spacing: 4) {
                Text("Public Domain — No Rights Reserved")
                    .font(.caption)
                    .fontWeight(.medium)

                Text("Do whatever you like with this.\nSource code included. No attribution required.\nNo conditions. Yours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Link("Source Code", destination: Self.sourceURL)
                .font(.caption)

            Divider()
                .padding(.horizontal, 40)

            // Perch owes its start to WindowPin, released into the public
            // domain by its author. The thanks belongs where people look.
            VStack(spacing: 4) {
                Text("Perch began as WindowPin, by Jonathan Hollin of Jorvik Software, who generously released it into the public domain. Thank you, Jonathan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Link("The original WindowPin", destination: Self.originalURL)
                    .font(.caption)
            }

            Button("Close") {
                NSApp.keyWindow?.close()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 300)
    }

    /// Cached window so repeat invocations focus the existing one instead
    /// of stacking duplicates. `isReleasedWhenClosed = false` keeps the
    /// object alive after the user closes it; we just re-show.
    private static var existingWindow: NSWindow?

    static func showWindow(appName: String) {
        if let window = existingWindow {
            // Whether it was closed or left open on another space, it comes to
            // this one; showing it never switches spaces.
            JorvikWindowHelper.showOnActiveSpace(window)
            return
        }

        let controller = NSHostingController(rootView: JorvikAboutView(appName: appName))

        controller.view.layoutSubtreeIfNeeded()

        let window = NSWindow(contentViewController: controller)
        window.title = "About \(appName)"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(controller.view.fittingSize)
        JorvikWindowHelper.showOnActiveSpace(window)
        existingWindow = window
    }
}
