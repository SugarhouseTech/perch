import AppKit

/// A brief badge over a window saying it was pinned, unpinned, or couldn't be.
///
/// Pinning a window changes nothing you can see while you are in its app: the
/// pin sits behind the real window until you switch away. Without this a
/// press of the shortcut looked like it had done nothing, and pressing again
/// undid it.
enum PinFeedbackHUD {

    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?
    /// Counts the badges shown, so a fade that is still finishing can tell it
    /// has been overtaken.
    private static var shown = 0

    static func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
    }

    static func show(_ text: String, windowID: CGWindowID? = nil) {
        show(text, over: targetFrame(windowID: windowID))
    }

    static func show(_ text: String, over frame: NSRect) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 22, weight: .semibold)
        label.textColor = .white
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 48, height: label.frame.height + 28)

        let p = panel ?? makePanel()
        panel = p
        let box = p.contentView!
        box.subviews.forEach { $0.removeFromSuperview() }
        label.frame.origin = NSPoint(x: 24, y: 14)
        box.addSubview(label)

        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        // Through the animator, so a fade still running is replaced.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            p.animator().alphaValue = 1
        }
        p.orderFrontRegardless()

        hideTask?.cancel()
        shown += 1
        let this = shown
        hideTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                p.animator().alphaValue = 0
            }, completionHandler: {
                // Cancelling the task does not stop a fade already under way.
                // Pinning and unpinning about a second apart put the new badge
                // up just in time for the old fade to take it down.
                MainActor.assumeIsolated {
                    if this == shown { p.orderOut(nil) }
                }
            })
        }
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .screenSaver
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        box.layer?.cornerRadius = 12
        p.contentView = box
        return p
    }

    /// Centred over the window, or over the main screen if its frame can't be read.
    private static func targetFrame(windowID: CGWindowID?) -> NSRect {
        var target = NSScreen.main?.frame ?? .zero
        if let windowID,
           let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]])?.first,
           let b = info[kCGWindowBounds as String] as? [String: CGFloat],
           let primary = NSScreen.screens.first {
            // Window bounds are top-left based; AppKit's are bottom-left from the primary screen.
            let w = b["Width"] ?? 0, h = b["Height"] ?? 0
            target = NSRect(x: b["X"] ?? 0, y: primary.frame.height - (b["Y"] ?? 0) - h, width: w, height: h)
        }
        return target
    }
}
