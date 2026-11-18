import Foundation

/// What happens to a window when the user unpins it, chosen in Settings.
/// An unpin the app makes by itself (capture refused) always just hides.
///
/// There is no "leave it in front but keep the keyboard where it is":
/// macOS will not put another app's window above the active app's without
/// making that app active, so the choice is between these two.
nonisolated enum UnpinBehavior: String, CaseIterable, Sendable {
    /// Bring the window to the front and give it the keyboard. The default:
    /// someone done with a window floating usually wants to use it next.
    case focus
    /// Take the pin away and nothing else, as unpinning always used to. The
    /// window stays wherever it was, usually behind the app in use.
    case hide

    static let key = "unpinBehavior"
    static let `default`: UnpinBehavior = .focus

    /// What is stored, or the default. A value no longer offered (an earlier
    /// build had a third choice) reads as the default.
    static func stored(in defaults: UserDefaults) -> UnpinBehavior {
        defaults.string(forKey: key).flatMap(UnpinBehavior.init(rawValue:)) ?? .default
    }

    var title: String {
        switch self {
        case .focus: "Bring it forward"
        case .hide: "Hide it"
        }
    }
}
