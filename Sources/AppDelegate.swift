import AppKit
import CoreGraphics
import ApplicationServices
import SwiftUI
import ServiceManagement

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private let tracker = PinnedWindowTracker()

    /// The last other app that was active, for the menu to fall back on when
    /// Perch itself is in front. Its window is looked up when the menu
    /// opens, not at every app switch.
    private var lastForeignApp: NSRunningApplication?
    private var badges: PinBadgeController?
    private var focusObserver: (any NSObjectProtocol)?

    var shortcutKeyCode: UInt16 = 35
    var shortcutModifiers: NSEvent.ModifierFlags = [.command, .control]

    /// The shortcut recorder calls this while it is listening, so pressing the
    /// shortcut that is already set records it instead of toggling a pin.
    func setHotkeySuspended(_ suspended: Bool) {
        HotkeyTap.shared.isSuspended = suspended
    }

    private var permissionTimer: Timer?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // There is no SwiftUI App to build a menu bar for us, so build one. It is
        // never drawn — an accessory app has no menu bar — but AppKit routes key
        // equivalents through it, which is what makes Command+Q quit and the
        // editing shortcuts work in the settings window's text fields.
        JorvikApplicationMenu.install()

        // Settings from before the rename to Perch, once.
        let carried = SettingsMigration.run(
            old: UserDefaults.standard.persistentDomain(forName: SettingsMigration.oldDomain),
            into: .standard)
        if !carried.isEmpty { wplog("Carried over \(carried.count) settings from WindowPin") }

        NSApp.setActivationPolicy(.accessory)

        // Every Accessibility call Perch makes waits on another app, and the
        // default timeout is about six seconds. Several run on the main thread,
        // where the hotkey's event tap also lives, so one hung app could stall
        // Perch and every keystroke in the system. Setting the timeout on the
        // system-wide element sets it for all elements that don't set their own.
        // A second is long enough for a slow app's first answer, short enough
        // that a hung one is no worse than a hiccup.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)

        // No prompt here. The system's own prompt used to go up at every
        // launch without Accessibility, login included; the setup window asks
        // instead, once, and says what it is for.
        wplog("Accessibility trusted: \(AXIsProcessTrusted())")
        // Accessibility is NOT the permission that lets an app post synthetic
        // events. Apple keeps three independent TCC buckets — Accessibility,
        // PostEvent and ListenEvent — as three separate rows, each tracked on
        // its own, and Perch has only ever checked the first. Forwarding a
        // click or a scroll to a pinned window is a *post*, so the one that
        // decides whether it arrives is PostEvent.
        wplog("PostEvent access: \(CGPreflightPostEventAccess())  ListenEvent access: \(CGPreflightListenEventAccess())")

        loadShortcut()
        republishHotkey()

        migrateLegacyPillColorKey()

        createStatusItem()

        NotificationCenter.default.observeOnMain(JorvikStatusItemVisibility.didChangeNotification) { [weak self] _ in
            self?.applyStatusItemVisibility()
        }

        tracker.onChange = { [weak self] in
            self?.updateIcon()
            self?.badges?.refresh()
        }
        tracker.onCaptureDenied = { [weak self] pw in
            PinFeedbackHUD.show("Unperched: allow Screen Recording", windowID: CGWindowID(pw.windowID))
            self?.showSetup()
        }
        tracker.onNeedsScreenRecording = { [weak self] in self?.showSetup() }
        badges = PinBadgeController(tracker: tracker) { [weak self] fw in
            guard let self else { return }
            let wasPinned = self.tracker.isPinned(windowID: fw.windowID)
            self.tracker.toggle(window: fw)
            self.showPinFeedback(wasPinned: wasPinned, window: fw)
        }

        focusObserver = NSWorkspace.shared.notificationCenter.observeOnMain(NSWorkspace.didActivateApplicationNotification) { [weak self] notification in
            guard let self = self else { return }
            self.recoverEventTapIfNeeded()
            // Covers coming back from System Settings with a permission
            // granted or taken away.
            self.refreshPermissionWarning()
            let myPID = ProcessInfo.processInfo.processIdentifier
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.processIdentifier != myPID {
                self.lastForeignApp = app
            }
        }

        registerHotkey()

        // Redraw the status icon when the display configuration changes — the
        // menu bar's effective thickness can shrink (e.g. moving from a notched
        // display to an external one) and leave the pre-rendered pill cropped.
        NotificationCenter.default.observeOnMain(NSApplication.didChangeScreenParametersNotification) { [weak self] _ in
            self?.updateIcon()
        }

        wplog("Launched successfully")

        // Shown without taking the keyboard: at login, it would otherwise
        // grab whatever the user had started typing into.
        if SetupWindow.shouldShowAtLaunch { SetupWindow.show(shortcut: shortcutDisplayString(), activate: false) }
    }

    @objc private func showSetup() {
        SetupWindow.show(shortcut: shortcutDisplayString())
    }

    // One-shot removal of the user-chosen pill colour key from the old design.
    // The new pill uses fixed grey/light colours; the key is dead weight.
    private func migrateLegacyPillColorKey() {
        let migrated = "didMigratePillColorV2"
        if UserDefaults.standard.bool(forKey: migrated) { return }
        UserDefaults.standard.removeObject(forKey: "menuBarPillColor")
        UserDefaults.standard.set(true, forKey: migrated)
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        HotkeyTap.shared.uninstall()
        if let obs = focusObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        tracker.unpinAll()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        JorvikStatusItemVisibility.handleReopen()
        // Launching the app again is the only way in when the menu-bar icon
        // can't be seen: hidden by a menu-bar manager, or crowded out of the
        // bar. Bring the icon back, as above, and open Settings so there is
        // something to see; or setup, while that is what stands in the way.
        if SetupWindow.isMissingPermission { showSetup() } else { openSettings() }
        return true
    }

    // MARK: - Status item

    func createStatusItem() {
        guard JorvikStatusItemVisibility.isVisible else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // No autosave name of our own. macOS gives the item the default one,
        // "Item-0", and remembers its place under that; menu bar managers such
        // as Bartender look items up by the default name and did not find this
        // one under a custom name. They also go by the label and tooltip, so
        // those are the app's name and never change.
        statusItem?.button?.toolTip = "Perch"
        statusItem?.button?.setAccessibilityLabel("Perch")
        updateIcon()

        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
    }

    func applyStatusItemVisibility() {
        if JorvikStatusItemVisibility.isVisible {
            if statusItem == nil { createStatusItem() }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // MARK: - Icon

    /// Whether the icon was last drawn with the warning dot.
    private var iconShowsWarning = false

    func updateIcon() {
        let hasPinned = !tracker.pinnedWindows.isEmpty
        let warning = SetupWindow.isMissingPermission
        iconShowsWarning = warning
        // The robin's orange breast (and the red warning dot) need an image
        // AppKit will not recolour, so the image is never a template, and the
        // bird is drawn in the menu bar's own text colour instead. The pill
        // picks a colour that contrasts with itself.
        let ownInk = !JorvikMenuBarPill.isEnabled
        let image = JorvikMenuBarPill.icon(
            drawGlyph: { @Sendable rect, color in
                let ink = ownInk ? Self.menuBarInk() : color
                MenuBarGlyph.draw(in: rect, color: ink, pinned: hasPinned, warning: warning)
            },
            glyphSize: MenuBarGlyph.size,
            tint: ownInk ? .labelColor : nil
        )
        image.accessibilityDescription = "Perch"
        statusItem?.button?.image = image
        // The label and tooltip never change, because menu bar managers find
        // the item by them; the state goes in the value.
        statusItem?.button?.setAccessibilityValue(
            warning ? "Needs permission" : hasPinned ? "Window perched" : nil)
    }

    /// Redraw the icon if a permission has been granted or lost since it was
    /// drawn. Cheap enough to call on every app switch, and it only replaces
    /// the image when the answer changed.
    private func refreshPermissionWarning() {
        if SetupWindow.isMissingPermission != iconShowsWarning { updateIcon() }
    }

    /// What a template image would be drawn in, for the appearance being
    /// drawn in now (the menu bar's, which follows the wallpaper).
    nonisolated private static func menuBarInk() -> NSColor {
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? .white : NSColor(white: 0, alpha: 0.85)
    }

    // MARK: - Dynamic menu (NSMenuDelegate)

    // Laid out as: anything to fix, the pin action, the pins, then the app.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        refreshPermissionWarning()

        // First, while it stands in the way: the menu bar icon's red dot
        // points here.
        if SetupWindow.isMissingPermission {
            let setupItem = NSMenuItem(title: "\u{26A0}\u{FE0E} Finish Setting Up\u{2026}", action: #selector(showSetup), keyEquivalent: "")
            setupItem.target = self
            menu.addItem(setupItem)
            menu.addItem(NSMenuItem.separator())
        }

        // The last other app is only a fallback, for when Perch itself is
        // in front. Its focused window is asked for now, so a window closed
        // since is never offered.
        let remembered = lastForeignApp.flatMap { $0.isTerminated ? nil : WindowDetector.focusedWindow(of: $0) }
        let targetWindow = WindowDetector.getFrontmostForeignWindow() ?? remembered

        if let fw = targetWindow {
            let isPinned = tracker.isPinned(windowID: fw.windowID)
            let displayName = fw.windowTitle.isEmpty ? fw.ownerName : fw.windowTitle
            let label = isPinned
                ? "Unperch \"\(truncate(displayName, max: 30))\""
                : "Perch \"\(truncate(displayName, max: 30))\""
            let item = NSMenuItem(title: label, action: #selector(toggleFrontmost), keyEquivalent: "")
            item.representedObject = fw
            // Shown so the shortcut can be learnt from here.
            if let key = shortcutKeyEquivalent {
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = shortcutModifiers
            }
            menu.addItem(item)
        } else {
            let item = NSMenuItem(title: "No window to perch", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if !tracker.pinnedWindows.isEmpty {
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: "Perched"))
            let front = targetWindow?.ownerPID
            for pw in PinPolicy.menuOrder(tracker.pinnedWindows, frontPID: front) {
                let item = NSMenuItem(title: pw.displayLabel, action: #selector(unpinMenuItem(_:)), keyEquivalent: "")
                item.representedObject = pw.windowID
                item.state = .on
                item.toolTip = "Unperch"
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem(title: "Unperch All", action: #selector(unpinAllAction), keyEquivalent: ""))
        }

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let aboutItem = NSMenuItem(title: "About Perch", action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(NSMenuItem(title: "Quit Perch", action: #selector(quit), keyEquivalent: "q"))
    }

    // MARK: - Actions

    @objc private func toggleFrontmost(_ sender: NSMenuItem) {
        guard let fw = sender.representedObject as? ForeignWindow else { return }
        let wasPinned = tracker.isPinned(windowID: fw.windowID)
        tracker.toggle(window: fw)
        showPinFeedback(wasPinned: wasPinned, window: fw)
    }

    @objc private func unpinMenuItem(_ sender: NSMenuItem) {
        guard let windowID = sender.representedObject as? UInt32 else { return }
        tracker.unpin(windowID: windowID, byUser: true)
        PinFeedbackHUD.show("Unperched", windowID: CGWindowID(windowID))
    }

    @objc private func unpinAllAction() {
        tracker.unpinAll()
    }

    @objc private func quit() {
        tracker.unpinAll()
        NSApp.terminate(nil)
    }

    // MARK: - About & Settings

    @objc private func openAbout() {
        JorvikAboutView.showWindow(appName: "Perch")
    }

    @objc private func openSettings() {
        let trackerRef = tracker
        let delegate = self
        JorvikSettingsView.showWindow(appName: "Perch", showsLaunchAtLogin: false) {
            PerchSettingsContent(tracker: trackerRef, delegate: delegate)
        }
    }

    // MARK: - Global hotkey (CGEvent tap)

    private func registerHotkey() {
        HotkeyTap.shared.action = { [weak self] in
            self?.togglePinFrontmostWindow()
        }
        HotkeyTap.shared.binding = currentBinding

        if !tryCreateEventTap() {
            wplog("registerHotkey: waiting for Accessibility permission…")
            startPermissionPolling()
        }
    }

    private var currentBinding: HotkeyBinding {
        HotkeyBinding(keyCode: Int64(shortcutKeyCode), modifiers: nsToCGModifiers(shortcutModifiers))
    }

    /// Wait for Accessibility, to install the hotkey's tap.
    ///
    /// macOS announces a change to Accessibility trust, so this listens for
    /// that instead of asking every two seconds. Two things from
    /// `JorvikPermissionWatcher` matter here: the announcement comes before
    /// the change is committed, so the tap is tried a moment later; and
    /// `AXIsProcessTrusted()` caches its answer, so a read taken too early pins
    /// the old one. So it is not read at all: creating the tap asks the system
    /// directly and simply fails until the permission is there. A slow retry
    /// backs up the announcement, which is long-standing but undocumented.
    private func startPermissionPolling() {
        if !observingAccessibility {
            observingAccessibility = true
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(accessibilityAnnounced),
                name: JorvikPermissionWatcher.accessibilityAnnouncement, object: nil,
                suspensionBehavior: .deliverImmediately)
        }
        permissionTimer?.invalidate()
        let timer = Timer.onMainUnscheduled(every: 30, repeats: true) { [weak self] in self?.retryEventTap() }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private var observingAccessibility = false
    private var permissionSettle: DispatchWorkItem?

    @objc private func accessibilityAnnounced() {
        guard permissionTimer != nil else { return }
        permissionSettle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.retryEventTap() }
        permissionSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + JorvikPermissionWatcher.commitSeconds + 0.5, execute: work)
    }

    private func retryEventTap() {
        guard permissionTimer != nil, tryCreateEventTap() else { return }
        wplog("registerHotkey: Accessibility granted, hotkey active")
        permissionTimer?.invalidate()
        permissionTimer = nil
        refreshPermissionWarning()
    }

    /// Revoking Accessibility (or removing and re-adding the app, as the README
    /// suggests) leaves our tap dead, and nothing else notices: the hotkey
    /// stays dead until relaunch. Called whenever the frontmost app changes,
    /// which covers coming back from System Settings. A dead tap is dropped so
    /// the permission poll can build a fresh one once Accessibility is granted
    /// again.
    ///
    /// While waiting, each app switch also tries the tap: the announcement of
    /// a grant can come before anything was listening for it (removed and
    /// re-added in one visit to System Settings), and the 30s backstop is too
    /// slow for someone who just granted it and came back.
    private func recoverEventTapIfNeeded() {
        if permissionTimer != nil {
            retryEventTap()
            return
        }
        let tap = HotkeyTap.shared
        guard tap.isInstalled, !tap.isHealthy else { return }
        wplog("recoverEventTap: tap is no longer usable, waiting for Accessibility permission…")
        tap.uninstall()
        startPermissionPolling()
        retryEventTap()
    }

    private func tryCreateEventTap() -> Bool {
        if HotkeyTap.shared.isInstalled { return true }
        guard HotkeyTap.shared.install() else {
            // No AXIsProcessTrusted() here: see `startPermissionPolling`.
            wplog("tryCreateEventTap: CGEvent.tapCreate failed")
            return false
        }
        wplog("tryCreateEventTap: SUCCESS — hotkey active for keyCode=\(shortcutKeyCode)")
        return true
    }

    private func togglePinFrontmostWindow() {
        guard let fw = WindowDetector.getFrontmostForeignWindow() else {
            wplog("togglePin: No foreign window found")
            return
        }
        let wasPinned = tracker.isPinned(windowID: fw.windowID)
        tracker.toggle(window: fw)
        showPinFeedback(wasPinned: wasPinned, window: fw)
        let action = wasPinned ? "Unperched" : "Perched"
        let title = fw.windowTitle.isEmpty ? fw.ownerName : fw.windowTitle
        wplog("togglePin: \(action) '\(title)' (wid=\(fw.windowID))")
    }

    private func showPinFeedback(wasPinned: Bool, window fw: ForeignWindow) {
        let isPinned = tracker.isPinned(windowID: fw.windowID)
        // Neither pinned before nor now: the pin was refused for want of Screen
        // Recording. The setup window, which the tracker has just asked for,
        // says so; a badge under it would only be in the way.
        guard isPinned || wasPinned else { return }
        PinFeedbackHUD.show(isPinned ? "Perched" : "Unperched", windowID: CGWindowID(fw.windowID))
    }

    // MARK: - Shortcut configuration

    private func loadShortcut() {
        // Go by whether a binding was ever saved, not by its values. A bare
        // function key is saved with no modifiers, and a cleared shortcut is
        // saved as key code 0 with no modifiers; testing the values would throw
        // both away on relaunch and bring back the default. A fresh install has
        // nothing saved, so it keeps the default.
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "shortcutKeyCode") != nil,
              defaults.object(forKey: "shortcutModifiers") != nil else { return }
        // Converted with care: a value that does not fit would trap here, at
        // launch, on every launch. One that is out of range is not a key or a
        // modifier set at all, so the default stands.
        guard let kc = UInt16(exactly: defaults.integer(forKey: "shortcutKeyCode")),
              let mod = UInt(exactly: defaults.integer(forKey: "shortcutModifiers")) else { return }
        shortcutKeyCode = kc
        shortcutModifiers = NSEvent.ModifierFlags(rawValue: mod)
            .intersection([.command, .control, .option, .shift])
    }

    func saveShortcutAndUpdateTap() {
        saveShortcut()
    }

    private func saveShortcut() {
        UserDefaults.standard.set(Int(shortcutKeyCode), forKey: "shortcutKeyCode")
        UserDefaults.standard.set(Int(shortcutModifiers.rawValue), forKey: "shortcutModifiers")
        HotkeyTap.shared.binding = currentBinding
        republishHotkey()
    }

    /// Push current binding to the JorvikKit registry so ShortcutHUD can list it.
    private func republishHotkey() {
        // A cleared binding is published as nothing rather than as key code 0,
        // which ShortcutHUD would otherwise list as the letter A.
        guard shortcutKeyCode != 0 || !shortcutModifiers.isEmpty else {
            JorvikHotkeyRegistry.publish([])
            return
        }
        JorvikHotkeyRegistry.publish([
            JorvikHotkey(actionTitle: "Perch or Unperch",
                         keyCode: shortcutKeyCode,
                         modifiers: shortcutModifiers,
                         activeContext: .anywhere),
        ])
    }

    // Shortcut recording is handled by JorvikShortcutRecorder in JorvikKit

    /// The shortcut's key as a menu item key equivalent, or nil when there
    /// is no shortcut or its key is not a plain character (an arrow, a
    /// function key): AppKit draws those from codes this does not map, and
    /// the menu simply shows no shortcut for them.
    private var shortcutKeyEquivalent: String? {
        guard shortcutKeyCode != 0 || !shortcutModifiers.isEmpty else { return nil }
        let key = keyCodeToCharacter(shortcutKeyCode)
        // A printable ASCII character: a letter, digit or punctuation key.
        guard key.count == 1, key.unicodeScalars.allSatisfy({ (33..<127).contains($0.value) }) else { return nil }
        return key.lowercased()
    }

    func shortcutDisplayString() -> String {
        // Say so rather than rendering key code 0 as the letter A.
        guard shortcutKeyCode != 0 || !shortcutModifiers.isEmpty else { return "Not set" }
        var parts: [String] = []
        if shortcutModifiers.contains(.control) { parts.append("⌃") }
        if shortcutModifiers.contains(.option) { parts.append("⌥") }
        if shortcutModifiers.contains(.shift) { parts.append("⇧") }
        if shortcutModifiers.contains(.command) { parts.append("⌘") }
        parts.append(keyCodeToCharacter(shortcutKeyCode))
        return parts.joined()
    }

    private func keyCodeToCharacter(_ keyCode: UInt16) -> String {
        let map: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
            50: "`", 51: "⌫", 53: "⎋",
            64: "F17", 79: "F18", 80: "F19", 90: "F20", 106: "F16",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
            101: "F9", 103: "F11", 105: "F13", 107: "F14", 109: "F10",
            111: "F12", 113: "F15", 118: "F4", 120: "F2", 122: "F1",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return map[keyCode] ?? "?\(keyCode)"
    }

    private func nsToCGModifiers(_ ns: NSEvent.ModifierFlags) -> CGEventFlags {
        var cg: CGEventFlags = []
        if ns.contains(.command) { cg.insert(.maskCommand) }
        if ns.contains(.control) { cg.insert(.maskControl) }
        if ns.contains(.option) { cg.insert(.maskAlternate) }
        if ns.contains(.shift) { cg.insert(.maskShift) }
        return cg
    }

    // MARK: - Helpers

    private func truncate(_ s: String, max: Int) -> String {
        s.count > max ? String(s.prefix(max)) + "…" : s
    }
}
