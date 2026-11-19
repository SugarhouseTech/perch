import SwiftUI
import ScreenCaptureKit

struct PerchSettingsContent: View {
    let tracker: PinnedWindowTracker
    let delegate: AppDelegate

    // @AppStorage (not computed Bindings) so SwiftUI's selection state stays in
    // sync with the store — a computed Binding here goes stale after the first
    // change and silently swallows every second interaction.
    // The default is the overlay's own, which is off on macOS 27 and later. A
    // literal `true` here drew the switch as on while nothing was stored and
    // the overlay was treating it as off.
    @AppStorage("forwardEvents") private var forwardEvents: Bool = WindowOverlay.forwardEvents
    @AppStorage("pinToAllSpaces") private var pinToAllSpaces: Bool = false
    @AppStorage(UnpinBehavior.key) private var unpinBehavior: UnpinBehavior = .default
    @AppStorage(PinBadgeController.pinnedKey) private var badgePinned: Bool = true
    @AppStorage(PinBadgeController.focusedKey) private var badgeFocused: Bool = true
    @AppStorage(PerchPermissionActions.askedAccessibilityKey) private var askedAccessibility = false

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
        if #available(macOS 27, *) { return "Scroll a perched window without switching to it" }
        return "Click and scroll a perched window without switching to it"
    }

    /// Only the tick is green: green text is too faint to read on a light window.
    fileprivate static var grantedLabel: some View {
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
            Toggle("Show a perch button in the title bar of the window you're using", isOn: $badgeFocused)
            Toggle("Show an unperch button on perched windows", isOn: $badgePinned)
            Picker(selection: $unpinBehavior) {
                ForEach(UnpinBehavior.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                Text("When you unperch a window")
            }
        }

        // The frame rate is not offered here: a perched window redraws only
        // when its window changes, so the default costs nothing for ordinary
        // windows, and nobody could tell what to set it to. It is still a
        // defaults setting, `captureRate` (see the README).
        Section("Perched Windows") {
            Toggle(isOn: $forwardEvents) {
                Text(Self.interactionTitle)
                if #available(macOS 27, *) {
                    Text("Vertical scrolling in apps that support it through Accessibility.")
                        .font(.settingsHelp)
                }
            }
            // The title alone as the label, and the help line as the hint,
            // so VoiceOver reads both, in that order.
            .accessibilityLabel(Self.interactionTitle)
            .accessibilityHint("Vertical scrolling in apps that support it through Accessibility.")

            Toggle("Show perched windows on every desktop", isOn: $pinToAllSpaces)
            .onChange(of: pinToAllSpaces) { _, _ in
                tracker.updateAllSpaces()
            }
        }

        Section("General") {
            JorvikLaunchAtLoginToggle()
            MenuBarPillToggle { delegate.updateIcon() }
        }

        #if PERCH_DIRECT
        LicenseSettingsSection()
        #endif

        MenuBarVisibilitySettings()

        Section("Permissions") {
            PermissionRow(title: "Accessibility",
                          help: "Perch needs to identify windows, scroll, and bring windows forward.",
                          granted: accessibility.isGranted) {
                Button(PerchPermissionActions.accessibilityButtonTitle(hasAsked: askedAccessibility),
                       action: PerchPermissionActions.requestAccessibility)
            }
            // The Settings window is cached, so these watchers would otherwise poll for the
            // life of the app once Settings had been opened.
            .jorvikPollsWhileVisible(accessibility, screenRecording)

            PermissionRow(title: "Screen Recording",
                          help: "Perch needs to see window contents to keep it on top.",
                          granted: screenRecording.isGranted) {
                Button("Grant Access") {
                    // The prompt only ever appears once; after a denial this silently
                    // records a request and returns false, so send them where they can
                    // actually flip it.
                    if !CGRequestScreenCaptureAccess() {
                        JorvikPermissionWatcher.openSettings(pane: .screenRecording)
                    }
                }
            }
        }

        BadgeOffsetSettings(badgeControlsEnabled: badgePinned || badgeFocused)
    }
}

/// A permission in Settings: what it is, why Perch needs it, and either
/// "Granted" or the button that asks for it. A plain row, because
/// LabeledContent names its button after the row, so VoiceOver read
/// "Accessibility" for the button that grants it.
private struct PermissionRow<Action: View>: View {
    let title: String
    let help: String
    let granted: Bool
    @ViewBuilder let action: Action

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(help).font(.settingsHelp)
            }
            Spacer()
            if granted { PerchSettingsContent.grantedLabel } else { action }
        }
    }
}
