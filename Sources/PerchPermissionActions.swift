import Foundation

/// Keeps the first Accessibility request and later recovery on the same path
/// wherever Perch exposes the permission.
enum PerchPermissionActions {
    static let askedAccessibilityKey = "askedAccessibility"

    static func accessibilityButtonTitle(hasAsked: Bool) -> String {
        hasAsked ? "Open System Settings" : "Allow…"
    }

    static func requestAccessibility() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: askedAccessibilityKey) else {
            defaults.set(true, forKey: askedAccessibilityKey)
            JorvikPermissionWatcher.promptForAccessibility()
            return
        }
        JorvikPermissionWatcher.openSettings(pane: .accessibility)
    }
}
