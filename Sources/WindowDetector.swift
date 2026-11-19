import AppKit
import ApplicationServices

nonisolated struct ForeignWindow: Hashable {
    let windowID: UInt32
    let ownerPID: pid_t
    let ownerName: String
    let windowTitle: String

    func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
    }

    static func == (lhs: ForeignWindow, rhs: ForeignWindow) -> Bool {
        lhs.windowID == rhs.windowID
    }
}

enum WindowDetector {

    /// Returns the frontmost window that does NOT belong to this process.
    static func getFrontmostForeignWindow() -> ForeignWindow? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        return focusedWindow(of: frontApp)
    }

    /// The focused window of `frontApp`, if it is another app's.
    static func focusedWindow(of frontApp: NSRunningApplication) -> ForeignWindow? {
        let myPID = ProcessInfo.processInfo.processIdentifier
        guard frontApp.processIdentifier != myPID else { return nil }

        // AX calls run on the main thread. Keep the timeout short for hung apps.
        let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        var axWindowRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &axWindowRef) == .success,
              let axWindow = WindowLevelManager.element(from: axWindowRef) else { return nil }

        AXUIElementSetMessagingTimeout(axWindow, 0.25)
        let axWindowID = WindowLevelManager.windowID(of: axWindow)
        var axTitle: String?
        var axBounds: CGRect?
        // If AX named an exact window, a different window is never a substitute.
        if axWindowID == nil {
            var titleRef: AnyObject?
            if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success {
                axTitle = titleRef as? String
            }
            var posRef: AnyObject?
            var sizeRef: AnyObject?
            if AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef) == .success,
               AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success,
               let pos = WindowLevelManager.point(from: posRef),
               let size = WindowLevelManager.size(from: sizeRef) {
                axBounds = CGRect(origin: pos, size: size)
            }
        }

        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        return matchFocusedWindow(id: axWindowID, title: axTitle, bounds: axBounds,
                                  ownerPID: frontApp.processIdentifier, ownerName: frontApp.localizedName ?? "Unknown",
                                  in: list)
    }

    nonisolated static func matchFocusedWindow(id: CGWindowID?, title: String?, bounds: CGRect?,
                                               ownerPID: pid_t, ownerName: String,
                                               in list: [[String: Any]]) -> ForeignWindow? {
        let candidates: [(window: ForeignWindow, bounds: CGRect?)] = list.compactMap { entry in
            guard entry[kCGWindowOwnerPID as String] as? pid_t == ownerPID,
                  entry[kCGWindowLayer as String] as? Int == 0,
                  let windowID = entry[kCGWindowNumber as String] as? CGWindowID,
                  id == nil || windowID == id else { return nil }
            let name = entry[kCGWindowName as String] as? String ?? ""
            let rect = (entry[kCGWindowBounds as String] as? NSDictionary)
                .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            return (ForeignWindow(windowID: windowID, ownerPID: ownerPID, ownerName: ownerName, windowTitle: name), rect)
        }
        if id != nil { return candidates.first?.window }

        let titleMatches = candidates.filter { !$0.window.windowTitle.isEmpty && $0.window.windowTitle == title }
        guard let bounds else { return titleMatches.count == 1 ? titleMatches.first?.window : nil }

        // Geometry can distinguish duplicate titles. When it disagrees with
        // a title match, wait for the next request instead of picking a side.
        let matches = (titleMatches.isEmpty ? candidates : titleMatches).filter {
            guard let rect = $0.bounds else { return false }
            return abs(rect.minX - bounds.minX) < 2 && abs(rect.minY - bounds.minY) < 2
                && abs(rect.width - bounds.width) < 2 && abs(rect.height - bounds.height) < 2
        }
        return matches.count == 1 ? matches.first?.window : nil
    }

    /// Minimized windows can still be in the all-windows inventory when an
    /// individual lookup returns nothing. Use the same inventory for every pin
    /// in a pruning pass so absence means the same thing for all of them.
    static func windowInventory() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    }

    static func windowExists(_ windowID: UInt32, ownerPID: pid_t) -> Bool? {
        windowInventory().map { containsWindow(windowID, ownerPID: ownerPID, in: $0) }
    }

    nonisolated static func containsWindow(_ windowID: UInt32, ownerPID: pid_t, in list: [[String: Any]]) -> Bool {
        list.contains {
            ($0[kCGWindowNumber as String] as? UInt32) == windowID
                && ($0[kCGWindowOwnerPID as String] as? pid_t) == ownerPID
        }
    }

}
