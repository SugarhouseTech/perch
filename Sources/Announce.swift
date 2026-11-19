import AppKit

/// Says something to VoiceOver now, for changes that happen away from where
/// its cursor is: a notice over another app's window, a key being refused, a
/// perched window going stale. Silent when VoiceOver is off.
enum Announce {
    static func say(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}
