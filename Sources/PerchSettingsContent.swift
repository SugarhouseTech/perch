import SwiftUI
import ScreenCaptureKit

struct PerchSettingsContent: View {
    let tracker: PinnedWindowTracker
    let delegate: AppDelegate

    // @AppStorage (not computed Bindings) so SwiftUI's selection state stays in
    // sync with the store — a computed Binding here goes stale after the first
    // change and silently swallows every second interaction.
    @AppStorage("captureRate") private var captureRate: Double = 30.0
    // The default is the overlay's own, which is off on macOS 27 and later. A
    // literal `true` here drew the switch as on while nothing was stored and
    // the overlay was treating it as off.
    @AppStorage("forwardEvents") private var forwardEvents: Bool = WindowOverlay.forwardEvents
    @AppStorage("pinToAllSpaces") private var pinToAllSpaces: Bool = false
    @AppStorage(UnpinBehavior.key) private var unpinBehavior: UnpinBehavior = .default
    @AppStorage(PinBadgeController.pinnedKey) private var badgePinned: Bool = true
    @AppStorage(PinBadgeController.focusedKey) private var badgeFocused: Bool = true

    /// Both kept current by JorvikKit — see `JorvikPermissionWatcher`. These two rows used
    /// to be read inline in `body`, so nothing ever caused them to re-render and granting
    /// either permission left the row still asking for it.
    @StateObject private var accessibility = JorvikPermissionWatcher.accessibility()
    @StateObject private var screenRecording = JorvikPermissionWatcher.screenRecording()

    /// The interaction switch says what it does on this Mac. It does less
    /// on macOS 27: a click can no longer be sent into another app's window
    /// there (see `WindowOverlay.forwardEvents`), so only scrolling is
    /// passed on.
    private static var interactionTitle: String {
        if #available(macOS 27, *) { return "Scroll perched windows in place" }
        return "Click and scroll perched windows in place"
    }

    private static var interactionCaption: String {
        if #available(macOS 27, *) {
            return "Scrolling over a perched window scrolls it, without leaving the app you're in. A click always takes you to the window itself."
        }
        return "Clicks and scrolls on a perched window go to it, without leaving the app you're in. \u{2318}-click to go to the window itself instead. When this is off, any click takes you to the window."
    }

    /// Only the tick is green: green text is too faint to read on a light window.
    private static var grantedLabel: some View {
        Label {
            Text("Granted")
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    // Everything below is a plain grouped form: no fonts, sizes or spacing of
    // its own. A second `Text` in a label is the row's description, which the
    // form sets in its own secondary style.
    // Ordered by how often each is likely to be wanted: pinning itself, how
    // pins behave, then the app, permissions, and per-app fixes last.
    // The words say what the user sees and gets, in the menu's terms: a
    // perched window is the floating copy of a window.
    var body: some View {
        Section("Perching") {
            JorvikShortcutRecorder(
                label: "Perch or unperch the window you're using",
                keyCode: Binding(
                    get: { delegate.shortcutKeyCode },
                    set: { delegate.shortcutKeyCode = $0 }
                ),
                modifiers: Binding(
                    get: { delegate.shortcutModifiers },
                    set: { delegate.shortcutModifiers = $0 }
                ),
                displayString: { delegate.shortcutDisplayString() },
                onChanged: { delegate.saveShortcutAndUpdateTap() },
                onClear: {
                    // Pinning stays available from the menu, which falls back
                    // to the last foreign window, so clearing costs nothing but
                    // the shortcut itself.
                    delegate.shortcutKeyCode = 0
                    delegate.shortcutModifiers = []
                    delegate.saveShortcutAndUpdateTap()
                },
                onRecordingChanged: { delegate.setHotkeySuspended($0) }
            )
            Toggle(isOn: $badgeFocused) {
                Text("Show a perch button on the window you're using")
                Text("A small button at the right of the title bar. Click it to perch the window.")
                    .font(.settingsHelp)
            }
            Toggle(isOn: $badgePinned) {
                Text("Show a perch button on perched windows")
                Text("Click it to unperch.")
                    .font(.settingsHelp)
            }
            Picker(selection: $unpinBehavior) {
                ForEach(UnpinBehavior.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                Text("When you unperch a window")
                Text("Bring it forward puts the window in front, ready to use. Hide it just lets go of the copy, and the window stays where it was, which may be behind other windows.")
                    .font(.settingsHelp)
            }
        }

        Section("Perched Windows") {
            Toggle(isOn: $forwardEvents) {
                Text(Self.interactionTitle)
                Text(Self.interactionCaption)
                    .font(.settingsHelp)
            }

            Toggle(isOn: $pinToAllSpaces) {
                Text("Show perched windows on every desktop")
                Text("When this is off, a perched window appears only on the desktop where you perched it. Desktops are the spaces you switch between in Mission Control.")
                    .font(.settingsHelp)
            }
            .onChange(of: pinToAllSpaces) { _, _ in
                tracker.updateAllSpaces()
            }

            Picker(selection: $captureRate) {
                Text("0.5 fps").tag(0.5)
                Text("1 fps").tag(1.0)
                Text("2 fps").tag(2.0)
                Text("5 fps").tag(5.0)
                Text("10 fps").tag(10.0)
                Text("15 fps").tag(15.0)
                Text("30 fps").tag(30.0)
                Text("60 fps").tag(60.0)
            } label: {
                Text("Update speed")
                Text("How many times a second (fps) a perched window can redraw, which matters for video and animation. It only redraws when its window changes, so a high setting costs nothing while the window is still.")
                    .font(.settingsHelp)
            }
            .onChange(of: captureRate) { _, _ in
                tracker.updateCaptureRate()
            }
        }

        Section("General") {
            JorvikLaunchAtLoginToggle()
            MenuBarPillToggle { delegate.updateIcon() }
        }

        MenuBarVisibilitySettings()

        Section("Permissions") {
            LabeledContent {
                if accessibility.isGranted {
                    Self.grantedLabel
                } else {
                    Button("Grant Access") {
                        JorvikPermissionWatcher.promptForAccessibility()
                    }
                }
            } label: {
                Text("Accessibility")
                Text("Lets the shortcut and perch buttons work, perched windows scroll, and windows come to the front.")
                    .font(.settingsHelp)
            }
            // The Settings window is cached, so these watchers would otherwise poll for the
            // life of the app once Settings had been opened.
            .jorvikPollsWhileVisible(accessibility, screenRecording)

            LabeledContent {
                if screenRecording.isGranted {
                    Self.grantedLabel
                } else {
                    Button("Grant Access") {
                        // The prompt only ever appears once; after a denial this silently
                        // records a request and returns false, so send them where they can
                        // actually flip it.
                        if !CGRequestScreenCaptureAccess() {
                            JorvikPermissionWatcher.openSettings(pane: .screenRecording)
                        }
                    }
                }
            } label: {
                Text("Screen Recording")
                Text("Lets a perched window show its live contents. Perch looks only at windows you perch, and saves and sends nothing.")
                    .font(.settingsHelp)
            }
        }

        // The least used: fixes for apps where the pin button lands badly.
        BadgeOffsetSettings()
            .disabled(!badgePinned && !badgeFocused)
    }
}
