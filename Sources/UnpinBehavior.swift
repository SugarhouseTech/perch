import Foundation

/// What happens to a window when the user unpins it, chosen in Settings.
/// An unpin the app makes by itself (capture refused) always just hides.
nonisolated enum UnpinBehavior: String, CaseIterable, Sendable {
    /// Bring the window to the front and give it the keyboard. The default:
    /// someone done with a window floating usually wants to use it next.
    case focus
    /// Leave the pin's live copy where it is, as an ordinary window, and the
    /// keyboard where it is. macOS will not put another app's window in
    /// front without also making that app active, so the copy stands in for
    /// the window until the user clicks it, switches to its app, or covers
    /// it (see `WindowOverlay.standIn`).
    case leaveInView
    /// Take the pin away and nothing else, as unpinning always used to. The
    /// window stays wherever it was, usually behind the app in use.
    case hide

    static let key = "unpinBehavior"
    static let `default`: UnpinBehavior = .focus

    static func stored(in defaults: UserDefaults) -> UnpinBehavior {
        defaults.string(forKey: key).flatMap(UnpinBehavior.init(rawValue:)) ?? .default
    }

    var title: String {
        switch self {
        case .focus: "Bring it forward"
        case .leaveInView: "Leave it in view"
        case .hide: "Hide it"
        }
    }

    enum Action: Equatable, Sendable {
        case hide
        case focusThenHide
        case standIn
    }

    /// - Parameter pinShowing: the pin is up and can be seen. When it is
    ///   not, the user is in the window's own app, where the real window is
    ///   already in view, or the pin is on another Space; either way there is
    ///   nothing to leave in view.
    func action(pinShowing: Bool) -> Action {
        switch self {
        case .hide: .hide
        case .focus: .focusThenHide
        case .leaveInView: pinShowing ? .standIn : .hide
        }
    }
}
