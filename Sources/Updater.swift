#if PERCH_DIRECT
import Sparkle

/// Sparkle, in the download from sugarhouse.tech only. The feed, its key and
/// the daily check are set in Info.plist by the release build. A build from
/// source never checks for updates.
enum Updater {
    /// Sparkle's own scheduled check is the only timer this adds: once a day.
    static let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    /// Here, not at the call, so only this file has to import Sparkle.
    static func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
#endif
