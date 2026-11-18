import Foundation

/// Where the pin button goes in apps that its automatic placement gets wrong:
/// a distance from the window's right edge to the button's, set per app in
/// Settings.
///
/// The automatic placement asks each app what lies along its title bar, and
/// most answer well. Some answer late, partly, or not at all, and an app's
/// title bar can change with any update. A fixed distance is the reliable
/// answer for those, and it costs the app nothing: an app with one is never
/// asked.
///
/// A distance in points rather than a share of the window's width, because
/// title-bar buttons are a fixed size and stay put against the right edge as a
/// window is resized.
nonisolated enum BadgeOffsets {

    /// The user's own distances, by bundle identifier.
    static let key = "badgeOffsets"
    /// Built-in distances the user removed.
    static let removedKey = "badgeOffsetsRemoved"
    /// Apps whose windows show the pin button only once pinned. The button
    /// that pins a window is left out; the one saying a window is pinned
    /// never is, as a pinned window with no sign of it would be a mystery.
    static let onlyWhenPinnedKey = "badgeOnlyWhenPinned"

    /// Where the automatic placement last put the button in each app, so an
    /// app added in Settings starts from there rather than from the corner.
    @MainActor static var lastAutomatic: [String: Double] = [:]

    /// From the right edge, as the automatic placement would have it with
    /// nothing in the way, to far enough left to clear any toolbar seen so far.
    static let range: ClosedRange<Double> = Double(TitleBarSlot.margin)...400

    /// Apps known to need a distance. Listed in Settings like any other, so
    /// what Perch is doing is visible and can be changed or removed.
    static let builtIn: [String: Double] = [
        // Inbox and help buttons at the right of its own title bar, which it
        // describes only seconds after first being asked, and piecemeal.
        "com.hnc.Discord": 90,
        // Describes nothing in its title bar, so the button went to the
        // corner, over the right sidebar's toggle, which every window has.
        // Surveyed 2026-11-18 alongside Chrome, VS Code, Messages, ChatGPT
        // and Claude, which needed nothing, and Music and Photos, where the
        // button sits at the end of the search field, which is acceptable.
        "md.obsidian": 40,
    ]

    /// The user's own distances. A value that is not a number is dropped
    /// rather than taking every other one with it.
    private static func own(in defaults: UserDefaults) -> [String: Double] {
        (defaults.dictionary(forKey: key) ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    /// Every app with a distance, built-in ones included.
    static func all(in defaults: UserDefaults = .standard) -> [String: Double] {
        let own = own(in: defaults)
        let removed = Set(defaults.stringArray(forKey: removedKey) ?? [])
        return builtIn.filter { !removed.contains($0.key) }
            .merging(own) { _, mine in mine }
            .mapValues { min(max($0, range.lowerBound), range.upperBound) }
    }

    static func set(_ distance: Double, for bundleID: String, in defaults: UserDefaults = .standard) {
        var own = own(in: defaults)
        own[bundleID] = distance
        defaults.set(own, forKey: key)
        var removed = defaults.stringArray(forKey: removedKey) ?? []
        if removed.contains(bundleID) {
            removed.removeAll { $0 == bundleID }
            defaults.set(removed, forKey: removedKey)
        }
    }

    static func onlyWhenPinned(in defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: onlyWhenPinnedKey) ?? [])
    }

    static func setOnlyWhenPinned(_ on: Bool, for bundleID: String, in defaults: UserDefaults = .standard) {
        var ids = onlyWhenPinned(in: defaults)
        guard ids.contains(bundleID) != on else { return }
        if on { ids.insert(bundleID) } else { ids.remove(bundleID) }
        defaults.set(ids.sorted(), forKey: onlyWhenPinnedKey)
    }

    /// The distance an app added in Settings starts at: its built-in one, or
    /// `automatic`, where the button already is (see `lastAutomatic`).
    static func starting(for bundleID: String, automatic: Double?) -> Double {
        let value = builtIn[bundleID] ?? automatic ?? range.lowerBound
        return min(max(value.rounded(), range.lowerBound), range.upperBound)
    }

    /// Back to automatic placement for the app, shown on every window.
    static func remove(_ bundleID: String, in defaults: UserDefaults = .standard) {
        setOnlyWhenPinned(false, for: bundleID, in: defaults)
        var own = own(in: defaults)
        if own.removeValue(forKey: bundleID) != nil { defaults.set(own, forKey: key) }
        if builtIn[bundleID] != nil {
            var removed = defaults.stringArray(forKey: removedKey) ?? []
            if !removed.contains(bundleID) {
                removed.append(bundleID)
                defaults.set(removed, forKey: removedKey)
            }
        }
    }

    /// A distance kept within the window: the button never leaves it, however
    /// narrow the window is.
    static func clamped(_ distance: CGFloat, width: CGFloat, side: CGFloat) -> CGFloat {
        max(TitleBarSlot.margin, min(distance, width - side - TitleBarSlot.margin))
    }
}
