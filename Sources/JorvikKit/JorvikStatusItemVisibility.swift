import AppKit
import SwiftUI

/// The app delegate observes visibility changes to create or remove its status item.
public enum JorvikStatusItemVisibility {

    /// Posted (locally) whenever the visibility flag changes. The app
    /// observes this to create or remove its status item.
    public static let didChangeNotification = Notification.Name(
        "cc.jorviksoftware.JorvikKit.StatusItemVisibilityDidChange"
    )

    private static let defaultsPrefix = "JorvikStatusItemVisibility.Hidden."

    private static var key: String {
        defaultsPrefix + (Bundle.main.bundleIdentifier ?? "unknown")
    }

    /// Whether the app's status-bar item should currently be shown.
    /// Persisted per-bundle; defaults to `true` (visible) for fresh installs.
    public static var isVisible: Bool {
        !UserDefaults.standard.bool(forKey: key)
    }

    /// Persist a new visibility state and broadcast the change. Call from
    /// the settings toggle.
    public static func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        UserDefaults.standard.set(!visible, forKey: key)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

public struct MenuBarVisibilitySettings: View {
    @State private var showIcon = JorvikStatusItemVisibility.isVisible

    public init() {}

    public var body: some View {
        Section("Menu Bar") {
            Toggle("Show in menu bar (top of screen)", isOn: $showIcon)
                .onChange(of: showIcon) { _, newValue in
                    JorvikStatusItemVisibility.setVisible(newValue)
                }
            if !showIcon {
                Label("Open Perch again from Applications to access Settings.", systemImage: "info.circle")
                    .font(.settingsHelp)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
