import AppKit

// Notification and timer callbacks scheduled on the main run loop do run on
// the main thread, but their closure types do not say so, and Swift 6 will not
// let them touch main actor state. These take a main actor handler instead and
// check the claim when it runs.

extension NotificationCenter {
    /// Observe `name`, delivered on the main thread. Keep the returned token
    /// and pass it to `removeObserver(_:)` to stop.
    @discardableResult
    func observeOnMain(
        _ name: Notification.Name, object: Any? = nil,
        _ handler: @escaping @MainActor (Notification) -> Void
    ) -> any NSObjectProtocol {
        addObserver(forName: name, object: object, queue: .main) { notification in
            // Delivered on the main queue: it never leaves this thread.
            nonisolated(unsafe) let notification = notification
            MainActor.assumeIsolated { handler(notification) }
        }
    }
}

extension Timer {
    /// A timer on the main run loop, in the default mode, like
    /// `scheduledTimer(withTimeInterval:repeats:block:)`.
    static func onMain(
        every interval: TimeInterval, repeats: Bool = true,
        _ handler: @escaping @MainActor () -> Void
    ) -> Timer {
        scheduledTimer(withTimeInterval: interval, repeats: repeats) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    /// The same timer, unscheduled, for adding to the run loop in other modes.
    static func onMainUnscheduled(
        every interval: TimeInterval, repeats: Bool = true,
        _ handler: @escaping @MainActor () -> Void
    ) -> Timer {
        Timer(timeInterval: interval, repeats: repeats) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }
}
