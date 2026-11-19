import AppKit
import CoreMedia
import ScreenCaptureKit

/// The window number behind an Accessibility window element. Private, but
/// unchanged for many macOS releases and relied on by window managers that
/// need to join the two worlds; there is no public equivalent.
@_silgen_name("_AXUIElementGetWindow")
nonisolated func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// A floating panel that mirrors a foreign window's content via a live
/// ScreenCaptureKit stream. Acts as a live "picture-in-picture" view that
/// stays on top of all windows.
///
/// Instead of hiding/showing (which causes flicker), the overlay stays on-screen
/// at all times and toggles between z-levels:
///   - `.floating` when the user is in another app (overlay visible above everything)
///   - below normal when the user is using the real window (overlay hidden behind it)
///
/// The stream only runs while the overlay is front — frames arrive only when
/// the window's content actually changes, and stopping the stream while the
/// overlay is hidden keeps the system's "screen recording" indicator away.
///
/// While the overlay is front, clicks and scrolls on it are forwarded to the
/// real window (see EventForwarder), so the pinned window can be scrolled and
/// clicked without switching apps. ⌘-click switches to the real window.
///
/// Option-drag crops the overlay to part of the window (see `crop`). A cropped
/// overlay is a small panel of its own: it can be dragged anywhere, resized by
/// its edges to show more or less of the window, and it
/// stays up while other windows of the same app are in use.
class WindowOverlay: NSPanel {

    let targetWindowID: CGWindowID
    let targetPID: pid_t

    private let contentLayer = CALayer()
    private let captureStatusView = NSView()
    private let captureStatusLabel = NSTextField(labelWithString: "")
    private let captureRetryButton = NSButton(title: "Retry", target: nil, action: nil)
    private var scWindow: SCWindow?
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "tech.sugarhouse.Perch.frames")
    /// Retains the pixel buffer whose IOSurface the layer currently displays,
    /// so ScreenCaptureKit can't recycle it out from under the layer.
    private var displayedFrame: CVPixelBuffer?
    private var frameSyncTimer: Timer?
    private var firstFrameDeadline: Timer?
    private var preShowDeadline: Timer?
    /// The part of the window the running stream was configured for, so a
    /// resize or a new crop can tell whether the stream needs reconfiguring.
    private var lastStreamGeometry: CGRect = .zero

    /// The part of the target window this pin shows, in points from the
    /// window's top-left corner. nil shows the whole window.
    ///
    /// Option-drag on a pin draws it; option-click on a cropped pin clears it.
    /// It is a fixed area of the window, so content that scrolls or reflows
    /// can move out of it. Moving the window is fine: the crop moves with it.
    private(set) var crop: CGRect?
    /// Where the user dragged a cropped pin to. nil keeps the pin over the
    /// area of the window it shows, following the window as it moves.
    private var movedOrigin: NSPoint?
    var isCropped: Bool { crop != nil }

    /// Called when a crop is set or cleared, so the tracker can start or stop
    /// deciding this pin's layering window by window. See `isTargetInUse`.
    var onCropChange: (() -> Void)?

    /// Option-drag in progress: where it started, in the panel's own points.
    private var selectionStart: NSPoint?
    private let selectionShade = CAShapeLayer()
    private let selectionBorder = CAShapeLayer()
    /// Plain drag on a cropped pin in progress: the pointer and the panel
    /// origin when it started, both in screen points.
    private var moveStart: (pointer: NSPoint, origin: NSPoint)?
    private var didMove = false
    /// Set by `mouseDown(with:)` when a press on a cropped pin reaches the
    /// content, meaning AppKit did not take it as a resize.
    private var pressReachedContent = false
    private var retryPressInProgress = false
    /// A press AppKit took (a resize) is in progress; its drags and release
    /// go to AppKit too.
    private var systemPressInProgress = false
    /// True while Perch itself is setting the panel's frame, so that the
    /// resize observer only reacts to the user resizing a cropped pin.
    private var applyingFrame = false
    /// The panel's frame after the last change that was accounted for, so a
    /// resize can tell which edges moved and by how much.
    private var lastPanelFrame: NSRect = .zero
    private var resizeObserver: (any NSObjectProtocol)?
    private var occlusionObserver: (any NSObjectProtocol)?
    /// When the stream runs, and what to do when it will not: every decision
    /// about it is made there, and carried out here. See `send`.
    private var life = StreamLifecycle()
    /// The wait after going behind before the stream stops. See
    /// `StreamLifecycle.behindGrace`.
    private var behindStop: DispatchWorkItem?
    /// A selection smaller than this either way is taken as a click, not a
    /// crop. It is also about as small as a pin can usefully be.
    private static let minimumCropSide: CGFloat = 16
    /// How far a plain press on a cropped pin must travel to be a move rather
    /// than a click. AppKit's own drag threshold is of the same order.
    private static let moveThreshold: CGFloat = 3
    /// Points→pixels scale of the capture, taken from the content filter.
    private var streamPixelScale: CGFloat = 2
    private var didLogFirstFrame = false
    /// Whether this copy has already explained the scroll fallback.
    private var showedScrollUnavailable = false
    /// Total frames delivered by the stream (diagnostics).
    private(set) var framesReceived = 0
    /// The screenshot taken before the pin is first shown is under way.
    private var isPreparingFirstShow = false
    private var firstShowWasPrepared = false
    /// The pin starts out of sight and should be got ready behind its window
    /// as soon as the window is found. See `prepareBehind`.
    private var wantsStaging = false
    /// The pin was removed: nothing may put it back on screen, including a
    /// screenshot that finishes afterwards.
    private var isRemoved: Bool { life.removed }

    /// Called once if capture is refused for want of Screen Recording, so the
    /// tracker can take the pin down. A pin that cannot be filmed is a blank
    /// or frozen panel sitting over the window it claims to show.
    var onCaptureDenied: (() -> Void)?

    /// Whether the overlay is currently in "pinned visible" mode.
    var isPinVisible: Bool { life.pinVisible }

    /// Maximum stream frame rate (configurable via UserDefaults "captureRate", default 30).
    /// The stream only delivers frames when the window content changes, so a
    /// high cap costs nothing for static content.
    static var captureRate: Double {
        let stored = UserDefaults.standard.double(forKey: "captureRate")
        return stored > 0 ? stored : 30.0
    }

    /// Whether pinned overlays appear on all Mission Control spaces.
    static var pinToAllSpaces: Bool {
        UserDefaults.standard.bool(forKey: "pinToAllSpaces")
    }

    /// Whether clicks/scrolls on an overlay are forwarded to the real window.
    /// Forward clicks and scrolls into the pinned window.
    ///
    /// **Defaults to off on macOS 27 and later.** Forwarding posts a synthetic
    /// CGEvent to the target process. Measured 2026-09-23 on 27.0 (26A428) with
    /// a purpose-built receiver app: the events arrive and bind to the correct
    /// window, but their location is always the window's top-left corner, so
    /// AppKit hit-tests the corner, finds no view and drops every one. Stamping
    /// the window resets the location; not stamping it leaves no window bound;
    /// no integer field carries the location (all 153 were tested); copying a
    /// real event does not help, nor does write ordering. The window server
    /// derives that location itself and will not take ours.
    ///
    /// Leaving it on there makes every click a silent no-op. Off, a click does
    /// the obvious thing and takes you to the real window. Earlier releases are
    /// unaffected and keep the old default.
    static var forwardEvents: Bool {
        if let stored = UserDefaults.standard.object(forKey: "forwardEvents") as? Bool {
            return stored
        }
        if #available(macOS 27, *) { return false }
        return true
    }

    struct Placement {
        var crop: CGRect?
        var movedOrigin: NSPoint?
    }

    var placement: Placement { Placement(crop: crop, movedOrigin: movedOrigin) }

    init(windowID: CGWindowID, pid: pid_t, placement: Placement = Placement()) {
        crop = placement.crop
        movedOrigin = placement.movedOrigin
        targetWindowID = windowID
        targetPID = pid

        let frame = Self.getWindowFrame(windowID: windowID)
            ?? NSRect(x: 100, y: 100, width: 800, height: 600)

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = Self.pinToAllSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.fullScreenAuxiliary]

        // Layer-hosting view: frames land straight on the layer as IOSurfaces,
        // no NSImage conversion.
        contentLayer.contentsGravity = .resize
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        let hostedContent = NSView(frame: container.bounds)
        hostedContent.layer = contentLayer
        hostedContent.wantsLayer = true
        hostedContent.autoresizingMask = [.width, .height]
        container.addSubview(hostedContent)
        contentView = container

        captureStatusView.wantsLayer = true
        captureStatusView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        captureStatusView.layer?.cornerRadius = 10
        captureStatusView.isHidden = true
        captureStatusView.frame = NSRect(x: 0, y: 0, width: 230, height: 52)
        captureStatusView.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        captureStatusLabel.textColor = .white
        captureStatusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        captureStatusLabel.frame = NSRect(x: 12, y: 17, width: 145, height: 18)
        captureRetryButton.target = self
        captureRetryButton.action = #selector(retryCapture)
        captureRetryButton.toolTip = "Retry capture"
        captureRetryButton.setAccessibilityLabel("Retry capture")
        captureRetryButton.frame = NSRect(x: 164, y: 10, width: 56, height: 32)
        captureStatusView.addSubview(captureStatusLabel)
        captureStatusView.addSubview(captureRetryButton)
        container.addSubview(captureStatusView)
        captureStatusView.setFrameOrigin(NSPoint(x: (frame.width - captureStatusView.frame.width) / 2,
                                                 y: (frame.height - captureStatusView.frame.height) / 2))

        // The option-drag selection: the outside is shaded, the inside left
        // clear, with a dashed edge. Sublayers survive each frame replacing
        // the content layer's contents.
        selectionShade.fillRule = .evenOdd
        selectionShade.fillColor = NSColor.black.withAlphaComponent(0.45).cgColor
        selectionBorder.fillColor = nil
        selectionBorder.strokeColor = NSColor.white.cgColor
        selectionBorder.lineWidth = 1.5
        selectionBorder.lineDashPattern = [6, 4]
        selectionBorder.shadowColor = NSColor.black.cgColor
        selectionBorder.shadowOpacity = 0.8
        selectionBorder.shadowRadius = 1
        selectionBorder.shadowOffset = .zero
        for layer in [selectionShade, selectionBorder] {
            layer.isHidden = true
            layer.actions = ["path": NSNull(), "hidden": NSNull()]
            contentLayer.addSublayer(layer)
        }

        applyWindowStyle()

        // Look the window up now, ready for when the pin is first shown.
        send(.created)

        resizeObserver = NotificationCenter.default.observeOnMain(NSWindow.didResizeNotification, object: self) { [weak self] _ in
            self?.cropFollowsResize()
            self?.updateCaptureStatus()
            self?.updateCaptureStatus()
        }
        occlusionObserver = NotificationCenter.default.observeOnMain(NSWindow.didChangeOcclusionStateNotification, object: self) { [weak self] _ in
            self?.occlusionChanged()
        }
    }

    /// The pin cannot be seen: it is on another Space, behind a full-screen
    /// app, or the display is asleep or locked. Its stream and frame sync are
    /// paused meanwhile, so a pinned video on another Space is not filmed at
    /// thirty frames a second for nobody.
    private func occlusionChanged() {
        let hidden = !occlusionState.contains(.visible)
        if hidden != life.outOfSight, isPinVisible {
            wplog("overlay: \(hidden ? "out of sight, pausing" : "back in sight, resuming") wid=\(targetWindowID)")
        }
        send(.occlusion(hidden: hidden))
    }

    // MARK: - Carrying out the stream's lifecycle

    /// Tell the lifecycle what happened, and do what it says.
    private func send(_ event: StreamLifecycle.Event) {
        if event == .streamFailed || event == .streamSetupFailed || event == .firstFrameTimedOut {
            firstFrameDeadline?.invalidate()
            firstFrameDeadline = nil
        }
        for effect in life.handle(event) { perform(effect) }
        updateCaptureStatus()
    }

    private func perform(_ effect: StreamLifecycle.Effect) {
        switch effect {
        case .startStream: startStream()
        case .stopStream: stopStream()
        case .startFrameSync: startFrameSync()
        case .stopFrameSync: stopFrameSync()
        case .syncFrame: syncFrameWithTarget()
        case .resolveWindow: resolveSCWindow()
        case .scheduleRetry:
            DispatchQueue.main.asyncAfter(deadline: .now() + StreamLifecycle.retryDelay) { [weak self] in
                self?.send(.retryFired)
            }
        case .scheduleBehindStop:
            behindStop?.cancel()
            let stop = DispatchWorkItem { [weak self] in self?.send(.behindGraceElapsed) }
            behindStop = stop
            DispatchQueue.main.asyncAfter(deadline: .now() + StreamLifecycle.behindGrace, execute: stop)
        case .cancelBehindStop:
            behindStop?.cancel()
            behindStop = nil
        case .reportDenied: onCaptureDenied?()
        case .gaveUp: wplog("overlay: giving up restarting stream wid=\(targetWindowID)")
        }
    }

    private func updateCaptureStatus() {
        let state = life.captureState
        guard life.pinVisible, !life.outOfSight,
              state == .starting || state == .reconnecting || state == .stopped else {
            captureStatusView.isHidden = true
            return
        }
        let width = min(230, max(14, frame.width - 8))
        let height = min(52, max(14, frame.height - 8))
        captureStatusView.setFrameSize(NSSize(width: width, height: height))
        captureStatusView.setFrameOrigin(NSPoint(x: (frame.width - width) / 2,
                                                 y: (frame.height - height) / 2))
        let compact = width < 180 || height < 42
        captureStatusLabel.isHidden = compact
        captureRetryButton.title = compact ? "↻" : "Retry"
        if compact {
            captureRetryButton.frame = captureStatusView.bounds.insetBy(dx: 1, dy: 1)
        } else {
            captureRetryButton.frame = NSRect(x: width - 66, y: 10, width: 56, height: 32)
            captureStatusLabel.frame = NSRect(x: 12, y: 17, width: width - 90, height: 18)
        }
        switch state {
        case .starting:
            captureStatusLabel.stringValue = "Starting capture…"
            captureRetryButton.isHidden = true
            captureStatusView.isHidden = compact
        case .reconnecting:
            captureStatusLabel.stringValue = "Reconnecting…"
            captureRetryButton.isHidden = true
            captureStatusView.isHidden = compact
        case .stopped:
            captureStatusLabel.stringValue = "Capture stopped"
            captureRetryButton.isHidden = false
            captureStatusView.isHidden = false
        case .idle, .live, .paused:
            captureStatusView.isHidden = true
        }
    }

    @objc private func retryCapture() {
        guard life.captureState == .stopped, life.pinVisible, !life.outOfSight else { return }
        scWindow = nil
        send(.retryRequested)
    }

    func isCaptureRetryEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            retryPressInProgress = false
            if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
                return false
            }
            retryPressInProgress = isRetryButtonHit(event)
            return retryPressInProgress
        case .leftMouseDragged:
            return retryPressInProgress
        case .leftMouseUp:
            defer { retryPressInProgress = false }
            return retryPressInProgress
        default:
            return false
        }
    }

    private func isRetryButtonHit(_ event: NSEvent) -> Bool {
        let point = captureRetryButton.convert(event.locationInWindow, from: nil)
        return !captureStatusView.isHidden && !captureRetryButton.isHidden
            && captureRetryButton.bounds.contains(point)
    }

    // MARK: - ScreenCaptureKit window resolution

    /// Look the window up in ScreenCaptureKit's list. One at a time; the
    /// lifecycle sees to that.
    private func resolveSCWindow() {
        Task { @MainActor in
            let result: Result<SCShareableContent, any Error>
            do {
                result = .success(try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false
                ))
            } catch {
                result = .failure(error)
            }
            guard !isRemoved else { return }
            switch result {
            case .success(let content):
                if let match = content.windows.first(where: { $0.windowID == targetWindowID && $0.owningApplication?.processID == targetPID }) {
                    self.scWindow = match
                    wplog("overlay: resolved SCWindow for wid=\(targetWindowID) title='\(match.title ?? "")'")
                    self.stageBehindIfReady()
                    self.send(.resolved(found: true))
                } else {
                    wplog("overlay: SCWindow NOT FOUND for wid=\(targetWindowID) (checked \(content.windows.count) windows)")
                    self.send(.resolved(found: false))
                }
            case .failure(let error):
                wplog("overlay: SCShareableContent error: \(error)")
                let denied = (error as NSError).code == SCStreamError.Code.userDeclined.rawValue
                self.send(.resolveFailed(denied: denied))
            }
        }
    }

    // MARK: - Event handling

    /// Drive the pinned window through Accessibility instead of forwarding
    /// events to it. macOS 27 only.
    ///
    /// On 27 a posted CGEvent cannot be placed inside another app's window —
    /// see `forwardEvents` — so scrolling a pin had simply stopped working.
    /// Setting the target's scroll position directly does work, and was
    /// measured on 2026-09-23 to scroll a background, occluded Finder window
    /// three times running without the frontmost app changing.
    ///
    /// Scroll only. There is no equivalent for a click: pressing a button
    /// through Accessibility would activate something the user only pointed
    /// at, so a click still takes you to the real window, which is the
    /// behaviour Jonathan said he prefers anyway.
    /// The target window's bounds in global top-left coordinates.
    static func windowBounds(_ windowID: CGWindowID) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let b = info.first?[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        return OverlayGeometry.bounds(fromWindowList: b)
    }

    private var usesAccessibilityScrolling: Bool {
        if #available(macOS 27, *) {
            // The same switch the user already knows, "Interact through
            // overlays". On 27 that means scrolling, since clicking now always
            // hands over. A second hidden knob would only be a way to get the
            // two out of step.
            return Self.forwardEvents
        }
        return false
    }

    /// The point in the target window under a point on the overlay, in global
    /// top-left coordinates. See `OverlayGeometry.targetPoint`.
    func targetPoint(forLocation loc: NSPoint, clamped: Bool = false) -> CGPoint? {
        guard let bounds = Self.windowBounds(targetWindowID) else { return nil }
        return OverlayGeometry.targetPoint(location: loc, panelSize: frame.size, window: bounds,
                                           crop: crop, clamped: clamped)
    }

    /// The part of the window on show, in points from its top-left corner.
    private func shownRect(windowSize: CGSize) -> CGRect {
        OverlayGeometry.shownRect(crop: crop, windowSize: windowSize)
    }

    override func sendEvent(_ event: NSEvent) {
        if isCaptureRetryEvent(event) {
            super.sendEvent(event)
            return
        }
        if isPinVisible, handleCropGesture(event) { return }

        if event.type == .scrollWheel, isPinVisible, usesAccessibilityScrolling {
            if let point = targetPoint(forLocation: event.locationInWindow) {
                let showHint: @MainActor @Sendable () -> Void = { [weak self] in
                    guard let self, self.isPinVisible, !self.isRemoved, self.occlusionState.contains(.visible),
                          self.usesAccessibilityScrolling, !self.showedScrollUnavailable else { return }
                    self.showedScrollUnavailable = true
                    PinFeedbackHUD.show("Can’t scroll here. Click to open.", over: self.frame)
                }
                AXScroller.scroll(pid: targetPID, windowID: targetWindowID,
                                  deltaY: event.scrollingDeltaY,
                                  precise: event.hasPreciseScrollingDeltas, at: point,
                                  onUnavailable: showedScrollUnavailable ? nil : showHint)
            }
            return
        }
        // macOS 27: a click never goes to the forwarder, whatever the setting
        // says. Forwarding cannot place an event inside another app's window
        // there, so routing a click into it makes the click silently do
        // nothing — which is what happened when this was left to a DEFAULT: a
        // value already stored on the machine beat the new default and the
        // click disappeared. Taking the user to the real window is the honest
        // response, and it is the behaviour Jonathan asked for.
        if #available(macOS 27, *), isPinVisible {
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                activateRealWindow()
                return
            case .leftMouseUp, .leftMouseDragged, .rightMouseUp, .rightMouseDragged,
                 .otherMouseUp, .otherMouseDragged:
                return      // the down already handed over; swallow the rest
            default:
                break
            }
        }

        guard isPinVisible, Self.forwardEvents else {
            super.sendEvent(event)
            return
        }
        switch event.type {
        case .leftMouseDown where event.modifierFlags.contains(.command):
            // Escape hatch: ⌘-click switches to the real window.
            activateRealWindow()
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged,
             .scrollWheel:
            EventForwarder.forward(event, from: self)
        default:
            super.sendEvent(event)
        }
    }

    /// Fallback when event forwarding is disabled: any click switches to the
    /// real window (the pre-forwarding behaviour).
    override func mouseDown(with event: NSEvent) {
        // A cropped pin sends presses through AppKit to find out whether they
        // are a resize; one that arrives here was not, and is handled by
        // `handleCropGesture` as a move or a click.
        if isCropped {
            pressReachedContent = true
            return
        }
        activateRealWindow()
    }

    /// A cropped pin is a titled window, which AppKit would otherwise let
    /// become key on a click. The pin must never take the keyboard from the
    /// app being worked in.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Put the pin behind and bring its real window forward, with the
    /// keyboard. Also used when the user unpins.
    func activateRealWindow() {
        wplog("overlay: switching to real window wid=\(targetWindowID)")
        sendBehind()
        // Explicitly activating: this is the deliberate "take me to the real
        // window" action, the one place where moving focus is the point.
        if !WindowLevelManager.raiseWindow(pid: targetPID, windowID: UInt32(targetWindowID), activate: true) {
            // The window could not be raised (its app did not answer, or would
            // not say which window is which). The pin has already gone behind,
            // and without an app switch nothing would bring it back, so the
            // click would simply make it vanish. Bring the app forward instead:
            // the nearest thing to what was asked for.
            NSRunningApplication(processIdentifier: targetPID)?.activate()
        }
    }

    // MARK: - Cropping

    /// Option-drag selects an area to crop to; option-click on a cropped pin
    /// shows the whole window again. On a cropped pin a plain drag moves it and
    /// a plain click still hands over to the real window. Returns whether the
    /// event was used.
    ///
    /// This runs before forwarding, on every macOS: a cropped pin is small and
    /// sits wherever the user put it, so moving it has to be possible, and an
    /// option-drag is no longer passed to the pinned app on macOS 26 and earlier.
    private func handleCropGesture(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown where event.modifierFlags.contains(.option):
            selectionStart = event.locationInWindow
            showSelection(to: event.locationInWindow)
            return true
        case .leftMouseDragged where selectionStart != nil:
            showSelection(to: event.locationInWindow)
            return true
        case .leftMouseUp where selectionStart != nil:
            finishSelection(at: event.locationInWindow)
            return true

        case .leftMouseDown where isCropped:
            // macOS decides whether a press is on the window's resize edge;
            // there is no public way to ask where that edge is. So the press
            // goes to AppKit first. A press anywhere but the edge reaches the
            // content and lands in `mouseDown(with:)`, which marks it as ours
            // to move or click. One on the edge starts a resize, which AppKit
            // carries on through the drags that follow (measured on 27.0.1:
            // this call returns at once, before any of them).
            pressReachedContent = false
            super.sendEvent(event)
            if pressReachedContent {
                moveStart = (NSEvent.mouseLocation, frame.origin)
                didMove = false
            } else {
                // AppKit took the press as a resize. It carries the resize on
                // through the drags that follow, so they must reach it.
                systemPressInProgress = true
            }
            return true
        case .leftMouseDragged where systemPressInProgress:
            super.sendEvent(event)
            return true
        case .leftMouseUp where systemPressInProgress:
            systemPressInProgress = false
            super.sendEvent(event)
            return true
        case .leftMouseDragged where moveStart != nil:
            guard let start = moveStart else { return true }
            let pointer = NSEvent.mouseLocation
            let dx = pointer.x - start.pointer.x, dy = pointer.y - start.pointer.y
            if didMove || OverlayGeometry.isMove(dx: dx, dy: dy, threshold: Self.moveThreshold) {
                didMove = true
                let origin = NSPoint(x: start.origin.x + dx, y: start.origin.y + dy)
                movedOrigin = origin
                setFrameOrigin(origin)
                lastPanelFrame = frame
            }
            return true
        case .leftMouseUp where moveStart != nil:
            moveStart = nil
            if !didMove { activateRealWindow() }
            return true

        default:
            return false
        }
    }

    /// Drop any crop, move or resize gesture in progress. A pin that goes
    /// behind no longer sees the release that would end it, which would
    /// leave the selection drawn and the next press read as part of it.
    private func cancelGesture() {
        selectionStart = nil
        selectionShade.isHidden = true
        selectionBorder.isHidden = true
        moveStart = nil
        systemPressInProgress = false
    }

    /// The selection from where the option-drag started to `point`, both in
    /// the panel's points, limited to the panel.
    private func selectionRect(to point: NSPoint) -> CGRect? {
        guard let start = selectionStart else { return nil }
        return OverlayGeometry.selectionRect(from: start, to: point, panelSize: frame.size)
    }

    private func showSelection(to point: NSPoint) {
        let panel = CGRect(origin: .zero, size: frame.size)
        let rect = selectionRect(to: point) ?? .zero
        let scale = backingScaleFactor
        let shade = CGMutablePath()
        shade.addRect(panel)
        shade.addRect(rect)
        for layer in [selectionShade, selectionBorder] {
            layer.frame = panel
            layer.contentsScale = scale
            layer.isHidden = false
        }
        selectionShade.path = shade
        // Inset by half the line so the edge is drawn inside the selection
        // and stays visible when it runs along the panel's edge.
        selectionBorder.path = CGPath(rect: rect.insetBy(dx: 0.75, dy: 0.75), transform: nil)
    }

    private func finishSelection(at point: NSPoint) {
        let rect = selectionRect(to: point)
        selectionStart = nil
        selectionShade.isHidden = true
        selectionBorder.isHidden = true

        guard let rect, OverlayGeometry.isCrop(rect, minimumSide: Self.minimumCropSide) else {
            // An option-click, or a selection too small to be one.
            if isCropped { setCrop(nil) }
            return
        }
        guard let windowSize = Self.windowBounds(targetWindowID)?.size,
              frame.width > 0, frame.height > 0 else { return }

        setCrop(OverlayGeometry.crop(forSelection: rect, panelSize: frame.size,
                                     windowSize: windowSize, current: crop))
    }

    private func setCrop(_ newCrop: CGRect?) {
        if let windowSize = Self.windowBounds(targetWindowID)?.size {
            showLastFrame(from: shownRect(windowSize: windowSize),
                          to: newCrop.map { $0.intersection(CGRect(origin: .zero, size: windowSize)) }
                              ?? CGRect(origin: .zero, size: windowSize))
        }
        crop = newCrop
        movedOrigin = nil
        if let newCrop {
            wplog("overlay: crop wid=\(targetWindowID) to \(Int(newCrop.minX)),\(Int(newCrop.minY)) \(Int(newCrop.width))x\(Int(newCrop.height))pt")
        } else {
            wplog("overlay: crop cleared wid=\(targetWindowID)")
        }
        // Changing the style can resize the panel, which must not be read as
        // the user resizing the new crop.
        applyingFrame = true
        applyWindowStyle()
        applyingFrame = false
        syncFrameWithTarget()
        updateCaptureStatus()
        onCropChange?()
    }

    /// A cropped pin looks like a window of its own, so it gets the system's
    /// window corners and edge. Neither has a public value to copy, so the pin
    /// becomes a titled window with an invisible title bar and macOS draws
    /// them, whatever the current release uses. A whole-window pin stays
    /// borderless: the window it shows already has its own corners.
    ///
    /// Moving is left to `handleCropGesture`, so the title bar must not move
    /// the window itself.
    private func applyWindowStyle() {
        let framed: NSWindow.StyleMask = [.titled, .fullSizeContentView, .resizable]
        let wanted = isCropped
        guard styleMask.isSuperset(of: framed) != wanted else { return }
        if wanted {
            styleMask.formUnion(framed)
            titleVisibility = .hidden
            titlebarAppearsTransparent = true
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                standardWindowButton(button)?.isHidden = true
            }
            isMovable = false
            contentMinSize = NSSize(width: Self.minimumCropSide, height: Self.minimumCropSide)
        } else {
            styleMask.subtract(framed)
        }
    }

    /// The user resized a cropped pin by one of its edges or corners. The crop
    /// moves the same edges by the same amount, so the pin shows more or less
    /// of the window around what it showed before, at the same scale. A crop
    /// cannot grow past the window, so the panel is trimmed back to it.
    private func cropFollowsResize() {
        guard isCropped, !applyingFrame,
              let (newCrop, _) = resizedCrop(from: lastPanelFrame, to: frame) else { return }
        crop = newCrop
        if movedOrigin != nil { movedOrigin = frame.origin }
        lastPanelFrame = frame
        syncFrameWithTarget()
    }

    /// The crop a resize from `old` to `new` asks for, and the panel frame
    /// that shows it. See `OverlayGeometry.resizedCrop`.
    private func resizedCrop(from old: NSRect, to new: NSRect) -> (CGRect, NSRect)? {
        guard let crop, let target = Self.getWindowFrame(windowID: targetWindowID),
              let resized = OverlayGeometry.resizedCrop(crop, from: old, to: new, windowSize: target.size)
        else { return nil }
        return (resized.crop, resized.panel)
    }

    /// AppKit resizes through here. A resize that would take a cropped pin
    /// past the edge of the window is trimmed before it is applied, so the
    /// edge stops at the window instead of overshooting and snapping back.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        if isCropped, !applyingFrame, inLiveResize,
           let (_, panel) = resizedCrop(from: lastPanelFrame, to: frameRect) {
            super.setFrame(panel, display: flag)
            return
        }
        super.setFrame(frameRect, display: flag)
    }

    /// Until the stream sends a frame of the new area, show the matching part
    /// of the frame already on the layer. The stream sends frames only when the
    /// window changes, so without this a quiet window would show its old,
    /// whole picture squeezed into the new panel. Clearing a crop has nothing
    /// to show beyond the old area, so the pin is left empty for that moment
    /// rather than stretched.
    private func showLastFrame(from old: CGRect, to new: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let rect = OverlayGeometry.contentsRect(current: contentLayer.contentsRect,
                                                      from: old, to: new) else {
            contentLayer.contents = nil
            displayedFrame = nil
            contentLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            return
        }
        contentLayer.contentsRect = rect
    }

    /// Whether the user is working in the pinned window itself: its app is
    /// frontmost and it is that app's front window.
    ///
    /// A whole-window pin drops behind whenever its app is active, which is
    /// right for it: it covers the window exactly. A cropped pin is small and
    /// often moved elsewhere, typically from a window torn off for the
    /// purpose, so it must stay up while another window of the same app is in
    /// use, such as a different Safari window.
    ///
    /// The app is asked for its main window through Accessibility. The window
    /// list cannot answer this: on macOS 27 the badge the system draws on a
    /// window being captured is a small normal-layer window owned by the
    /// captured app, in front of it, so the app's front window in the list is
    /// never the pinned one (measured 2026-10-11, TextEdit).
    ///
    /// The main window is identified by its window number, not by matching
    /// frames as `WindowLevelManager.axWindow` does: every tab in a tab group
    /// is its own window with the same frame, so a frame match cannot tell the
    /// selected tab from the one pinned.
    var isTargetInUse: Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else { return false }
        let app = AXUIElementCreateApplication(targetPID)
        // Asked twice a second on the main thread: a hung app must not hold it up.
        AXUIElementSetMessagingTimeout(app, 0.1)
        var mainRef: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &mainRef) == .success,
              let main = mainRef, CFGetTypeID(main) == AXUIElementGetTypeID() else { return false }
        var mainID: CGWindowID = 0
        guard _AXUIElementGetWindow(main as! AXUIElement, &mainID) == .success else { return false }
        return mainID == targetWindowID
    }

    // MARK: - Z-level transitions (no hide/show, just level changes)

    /// Make overlay visible above all windows and start the live stream.
    func bringToFront() {
        // A removed pin stays removed: raising it would put a blank panel up.
        guard !isRemoved else { return }
        guard !isPinVisible else {
            wplog("overlay: bringToFront skipped (already front) wid=\(targetWindowID)")
            return
        }
        wplog("overlay: bringToFront wid=\(targetWindowID)")
        let onScreen = isVisible
        // Brings the frame up to date first, so the pin is raised where its
        // window is now, not where it was when it went behind.
        send(.broughtToFront(onScreen: onScreen))
        if onScreen {
            // Already on screen but behind: just raise it. The last streamed
            // frame is still on the layer, so there is content until fresh
            // frames land.
            level = .floating
            setShown(true)
            orderFront(nil)
        } else {
            // First time: put it on screen with content already in place.
            doInitialShow()
        }
    }

    /// Drop overlay behind all normal windows (invisible to user, but still on-screen).
    func sendBehind() {
        guard isPinVisible else { return }
        wplog("overlay: sendBehind wid=\(targetWindowID)")
        send(.sentBehind)
        cancelGesture()
        // Not yet shown for the first time: there is nothing to put behind,
        // and ordering it back would put an empty panel on screen.
        guard isVisible else { return }
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) - 1)
        setShown(false)
        orderBack(nil)
    }

    /// Behind is below every normal window, which hides the pin only for as
    /// long as its own window sits exactly on top of it. It stops following
    /// the window while it is behind, so moving, resizing, minimising or
    /// closing the window left a frozen copy of it on the desktop, and a
    /// click on that copy brought the real window forward. So a pin that is
    /// behind is also transparent and takes no clicks. It stays on screen,
    /// as before, which is what avoids a flicker when it comes back.
    private func setShown(_ shown: Bool) {
        // Through the animator with no duration, so a fade-in still running
        // is replaced rather than left to finish at full opacity.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            self.animator().alphaValue = shown ? 1 : 0
        }
        ignoresMouseEvents = !shown
    }

    /// Start the stream again on a pin that is showing but has none: it gave
    /// up restarting, or lost its stream while the Mac slept or the displays
    /// changed. Without this such a pin kept its last frame until it next went
    /// behind and came back. Called whenever the active app changes, on wake
    /// and when the displays change.
    ///
    /// - Parameter force: a wake or a display change, which really can end a
    ///   stream. Otherwise, at most once every half minute: a pin whose stream
    ///   will not start would else get five more tries at every app switch,
    ///   each a full listing of every window.
    func reviveStreamIfNeeded(force: Bool = false) {
        // Asked afresh rather than trusting the last report.
        let effects = life.handle(.revive(force: force, now: ProcessInfo.processInfo.systemUptime,
                                          onScreen: isVisible, hidden: !occlusionState.contains(.visible)))
        if effects.contains(.startStream) { wplog("overlay: reviving stream wid=\(targetWindowID)") }
        effects.forEach(perform)
        updateCaptureStatus()
    }

    /// Fully remove overlay from screen (used when unpinning / cleaning up).
    func hideOverlay() {
        wplog("overlay: hideOverlay wid=\(targetWindowID)")
        wantsStaging = false
        isPreparingFirstShow = false
        preShowDeadline?.invalidate()
        preShowDeadline = nil
        send(.removed)
        AXScroller.forget(windowID: targetWindowID)
        cancelGesture()
        for token in [resizeObserver, occlusionObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(token)
        }
        resizeObserver = nil
        occlusionObserver = nil
        orderOut(nil)
    }

    // MARK: - Initial show (first time only)

    /// Get a pin that starts out of sight ready to come up without a gap.
    ///
    /// A pin usually starts behind its window, the one in use, and first comes
    /// up when the user switches to another app. It used to take its first
    /// screenshot only then: the new app's windows covered the real one at
    /// once, and the pin appeared about a quarter of a second later (the
    /// screenshot, then a fade), which reads as the window blinking. So the
    /// screenshot is taken now, while the window is in front and in full view,
    /// and the pin waits behind it, invisible, exactly as it does after every
    /// later switch. The first switch then simply makes it opaque.
    func prepareBehind() {
        wantsStaging = true
        stageBehindIfReady()
    }

    private func stageBehindIfReady() {
        guard wantsStaging, !isRemoved, !isVisible, !isPinVisible, !isPreparingFirstShow,
              let scWindow else { return }
        wantsStaging = false
        beginPreShowCapture(scWindow)
    }

    private func beginPreShowCapture(_ scWindow: SCWindow) {
        isPreparingFirstShow = true
        syncFrameWithTarget()
        preShowDeadline?.invalidate()
        preShowDeadline = Timer.onMain(every: 1, repeats: false) { [weak self] in
            self?.finishPreShowCapture(image: nil)
        }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = makeStreamConfig(pixelScale: CGFloat(filter.pointPixelScale))
        let windowID = targetWindowID
        Task { @MainActor [weak self] in
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                self?.finishPreShowCapture(image: image)
            } catch {
                wplog("overlay: pre-show capture failed wid=\(windowID): \(error)")
                self?.finishPreShowCapture(image: nil)
            }
        }
    }

    private func finishPreShowCapture(image: CGImage?) {
        guard isPreparingFirstShow else { return }
        isPreparingFirstShow = false
        preShowDeadline?.invalidate()
        preShowDeadline = nil
        guard !isRemoved, !isVisible else { return }
        firstShowWasPrepared = true
        // A late one-shot screenshot must not replace a live stream frame.
        if let image, life.captureState != .live {
            contentLayer.contents = image
        }
        if isPinVisible {
            fadeIn()
            return
        }
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) - 1)
        setShown(false)
        orderBack(nil)
        wplog("overlay: ready behind wid=\(targetWindowID)")
    }

    private func doInitialShow() {
        if firstShowWasPrepared {
            fadeIn()
            return
        }
        guard let scWindow = self.scWindow else {
            // SCWindow not resolved yet — show immediately, stream will fill in
            fadeIn()
            return
        }
        // Going behind and coming back while the screenshot is being taken
        // must not take a second one and fade in twice.
        guard !isPreparingFirstShow else { return }

        // Grab one screenshot BEFORE showing so the first visible frame has
        // content — the stream takes a beat to deliver its first frame.
        beginPreShowCapture(scWindow)
    }

    private func fadeIn() {
        guard !isRemoved else { return }
        level = .floating
        alphaValue = 0
        ignoresMouseEvents = false
        orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            self.animator().alphaValue = 1
        }
        send(.fadedIn)
    }

    // MARK: - Live stream

    /// Create and start a stream for the window. Only ever on the
    /// lifecycle's word, which knows none is running and the window is known.
    private func startStream() {
        // One stream at a time. The lifecycle never asks for a second; if it
        // somehow did, the one running stays and it stays counted as running.
        guard stream == nil else { return }
        guard let scWindow = self.scWindow else {
            send(.streamSetupFailed)
            return
        }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        // Capture at the window's true native scale: 1:1 pixels need no
        // resampling at composite time, which is what keeps text sharp.
        let filterScale = CGFloat(filter.pointPixelScale)
        streamPixelScale = filterScale >= 1 ? filterScale : displayScale
        targetScreenScale = Self.getWindowFrame(windowID: targetWindowID).flatMap(Self.screenScale(under:))
        let config = makeStreamConfig(pixelScale: streamPixelScale)
        lastStreamGeometry = currentStreamGeometry()
        didLogFirstFrame = false
        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        } catch {
            wplog("overlay: addStreamOutput failed wid=\(targetWindowID): \(error)")
            send(.streamSetupFailed)
            return
        }
        stream = newStream
        wplog("overlay: stream starting wid=\(targetWindowID) maxFPS=\(Self.captureRate)")
        firstFrameDeadline?.invalidate()
        firstFrameDeadline = Timer.onMain(every: 8, repeats: false) { [weak self] in
            self?.send(.firstFrameTimedOut)
        }
        Task { [weak self] in
            do {
                try await newStream.startCapture()
                // Stopped or replaced while it was starting: a stop sent then
                // fails, and the stream would go on capturing with no owner.
                guard self?.stream !== newStream else { return }
                wplog("overlay: stopping a stream replaced while starting")
                try? await newStream.stopCapture()
            } catch {
                wplog("overlay: startCapture failed wid=\(self?.targetWindowID ?? 0): \(error)")
                guard let self, self.stream === newStream else { return }
                self.stream = nil
                self.send(.streamFailed)
            }
        }
    }

    private func stopStream() {
        firstFrameDeadline?.invalidate()
        firstFrameDeadline = nil
        reconfigureTimer?.invalidate()
        reconfigureTimer = nil
        guard let stream = stream else { return }
        self.stream = nil
        Task {
            do { try await stream.stopCapture() } catch {
                wplog("overlay: stopCapture error: \(error)")
            }
        }
    }

    /// Apply the current capture-rate setting / frame size to a running stream.
    func applyCaptureRate() {
        guard let stream = stream else { return }
        let config = makeStreamConfig(pixelScale: streamPixelScale)
        Task { [weak self] in
            do { try await stream.updateConfiguration(config) } catch {
                wplog("overlay: updateConfiguration (rate) error: \(error)")
                // Forget what the stream was last set up for, so the next
                // frame sync sees a difference and tries again. Left as it
                // was, the stream kept its old size for good, and a cropped
                // pin, which waits for a frame of the new size, never updated
                // again.
                guard let self, self.stream === stream else { return }
                self.lastStreamGeometry = .zero
            }
        }
    }

    /// Resizing a cropped pin changes its geometry on every step of the drag,
    /// and reconfiguring the stream on each one asked ScreenCaptureKit for
    /// more updates than it can apply. The stream is reconfigured at most this
    /// often, and always once more after the last change so it ends up right.
    /// A frame of the old size meanwhile is stretched to the panel, not
    /// dropped, so the pin keeps showing something throughout.
    private static let reconfigureInterval: CFTimeInterval = 0.1
    private var lastReconfigure: CFTimeInterval = 0
    private var reconfigureTimer: Timer?

    private func reconfigureStream() {
        let wait = lastReconfigure + Self.reconfigureInterval - CACurrentMediaTime()
        guard wait > 0 else {
            reconfigureTimer?.invalidate()
            reconfigureTimer = nil
            lastReconfigure = CACurrentMediaTime()
            applyCaptureRate()
            return
        }
        guard reconfigureTimer == nil else { return }
        // Common modes, so it fires during the live resize itself.
        let timer = Timer.onMainUnscheduled(every: wait, repeats: false) { [weak self] in
            guard let self else { return }
            self.reconfigureTimer = nil
            self.lastReconfigure = CACurrentMediaTime()
            self.applyCaptureRate()
        }
        RunLoop.main.add(timer, forMode: .common)
        reconfigureTimer = timer
    }

    func updateCollectionBehavior() {
        collectionBehavior = Self.pinToAllSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.fullScreenAuxiliary]
    }

    /// Backing scale of the screen the overlay (or its target frame) is on.
    private var displayScale: CGFloat {
        if let screen = screen { return screen.backingScaleFactor }
        let f = frame
        if let match = NSScreen.screens.first(where: { $0.frame.intersects(f) }) {
            return match.backingScaleFactor
        }
        return NSScreen.main?.backingScaleFactor ?? 2
    }

    /// The scale of the display the target window was on when the stream's
    /// scale was last decided, so moving it to another display can be seen.
    private var targetScreenScale: CGFloat?

    /// Backing scale of the display holding most of `rect`, in screen points.
    private static func screenScale(under rect: NSRect) -> CGFloat? {
        OverlayGeometry.scale(under: rect,
                              displays: NSScreen.screens.map { ($0.frame, $0.backingScaleFactor) })
    }

    private func makeStreamConfig(pixelScale: CGFloat) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        // Size the output to the window's native pixels and pin the resolution
        // to .best — .automatic can deliver nominal (1x) frames that end up
        // stretched over a Retina layer, which reads as a slightly blurred pin.
        let pixels = OverlayGeometry.outputPixels(panelSize: frame.size, scale: pixelScale)
        config.width = pixels.width
        config.height = pixels.height
        // A crop films only that part of the window. For a single-window
        // filter the rectangle is in points from the window's top-left corner.
        if let windowSize = Self.windowBounds(targetWindowID)?.size,
           let crop = OverlayGeometry.clampedCrop(crop, windowSize: windowSize) {
            config.sourceRect = crop
        }
        config.captureResolution = .best
        config.scalesToFit = true
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = OverlayGeometry.queueDepth(width: config.width, height: config.height)
        config.minimumFrameInterval = CMTime(
            seconds: 1.0 / max(Self.captureRate, 0.1),
            preferredTimescale: 600
        )
        return config
    }

    // MARK: - Frame sync (follow the target window while visible)

    private func startFrameSync() {
        frameSyncTimer?.invalidate()
        frameSyncTimer = Timer.onMain(every: 0.5, repeats: true) { [weak self] in
            self?.syncFrameWithTarget()
        }
        frameSyncTimer?.tolerance = 0.1
    }

    private func stopFrameSync() {
        frameSyncTimer?.invalidate()
        frameSyncTimer = nil
    }

    private func syncFrameWithTarget() {
        guard let target = Self.getWindowFrame(windowID: targetWindowID) else { return }
        let wanted = panelFrame(forTarget: target)
        if frame != wanted {
            applyingFrame = true
            setFrame(wanted, display: false)
            applyingFrame = false
            updateCaptureStatus()
        }
        lastPanelFrame = frame
        // Window resized or crop changed → the stream's output size and the
        // area it films need to follow.
        let geometry = streamGeometry(windowSize: target.size, panelSize: wanted.size)
        // So does its pixel size when the window moves between a Retina and a
        // standard display, or the frames come out twice the size or blurred
        // until the pin is restarted. The filter's scale was fixed when the
        // stream started, so the display's own scale is used instead.
        var scaleChanged = false
        if stream != nil, let scale = Self.screenScale(under: target),
           let before = targetScreenScale, scale != before {
            wplog("overlay: display scale \(before)x -> \(scale)x wid=\(targetWindowID)")
            targetScreenScale = scale
            streamPixelScale = scale
            scaleChanged = true
        }
        if stream != nil, scaleChanged || !geometry.equalTo(lastStreamGeometry) {
            lastStreamGeometry = geometry
            reconfigureStream()
        }
    }

    /// Where the panel goes: over the whole window, over the cropped area of
    /// it, or wherever the user dragged a cropped pin to.
    private func panelFrame(forTarget target: NSRect) -> NSRect {
        OverlayGeometry.panelFrame(target: target, crop: crop, movedOrigin: movedOrigin)
    }

    /// What the stream must be configured for. See `OverlayGeometry.streamGeometry`.
    private func streamGeometry(windowSize: CGSize, panelSize: CGSize) -> CGRect {
        OverlayGeometry.streamGeometry(crop: crop, windowSize: windowSize, panelSize: panelSize)
    }

    private func currentStreamGeometry() -> CGRect {
        let windowSize = Self.windowBounds(targetWindowID)?.size ?? frame.size
        return streamGeometry(windowSize: windowSize, panelSize: frame.size)
    }

    // MARK: - Coordinate conversion (CG top-left → NS bottom-left)

    static func getWindowFrame(windowID: CGWindowID) -> NSRect? {
        guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let entry = info.first,
              let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        // The screen list can be empty for a moment while displays are being
        // reconfigured; there is no frame to give until it is back.
        guard let screenHeight = NSScreen.screens.first?.frame.height else { return nil }
        return OverlayGeometry.appKitFrame(fromWindowList: OverlayGeometry.bounds(fromWindowList: bounds),
                                           primaryHeight: screenHeight)
    }

    // No deinit: `hideOverlay()` is the teardown, and the tracker calls it
    // before letting a pin go. A main actor class's deinit can run on any
    // thread, where none of this cleanup would be safe.
}

// MARK: - SCStreamOutput / SCStreamDelegate

// ScreenCaptureKit calls these on `sampleQueue`, not the main thread, so they
// are nonisolated and hand what they have to the main thread themselves.
extension WindowOverlay: SCStreamOutput, SCStreamDelegate {

    /// A frame on its way to the main thread. Once handed over, nothing on the
    /// sample queue touches it again, which the compiler cannot see.
    nonisolated private struct Frame: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let surface: IOSurfaceRef
    }

    /// Whether a callback came from the stream now running. The stream itself
    /// stays on its own queue; only its identity crosses to the main thread.
    private func isCurrent(_ stream: ObjectIdentifier) -> Bool {
        self.stream.map(ObjectIdentifier.init) == stream
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                  sampleBuffer, createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              statusRaw == SCFrameStatus.complete.rawValue,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer) else { return }

        let frame = Frame(pixelBuffer: pixelBuffer, surface: surface.takeUnretainedValue())
        let from = ObjectIdentifier(stream)
        DispatchQueue.main.async { [weak self] in
            // Frames from a stream already replaced or stopped can still be on
            // their way here. They are of the old size or the old crop.
            guard let self, self.isCurrent(from) else { return }
            let pixelBuffer = frame.pixelBuffer, surfaceRef = frame.surface
            self.framesReceived += 1
            if !self.didLogFirstFrame {
                self.didLogFirstFrame = true
                wplog("overlay: first frame \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))px for \(Int(self.frame.width))x\(Int(self.frame.height))pt @\(self.streamPixelScale)x wid=\(self.targetWindowID)")
                // Stage B measurement, behind its own flag. See AXScroller.
                AXScroller.probe(pid: self.targetPID, windowID: self.targetWindowID)
            }
            let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
            if self.contentLayer.contentsRect != unit {
                // Showing part of an old frame after a crop change. Only a
                // frame sized for the new panel is of the new area; frames of
                // the old area can still be in flight and must not be shown
                // whole in the new panel.
                let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
                let wantW = Int(self.frame.width * self.streamPixelScale)
                let wantH = Int(self.frame.height * self.streamPixelScale)
                guard abs(w - wantW) <= 2, abs(h - wantH) <= 2 else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.contentLayer.contentsRect = unit
                self.displayedFrame = pixelBuffer
                self.contentLayer.contents = surfaceRef
                CATransaction.commit()
                self.acceptFirstFrameIfNeeded()
                return
            }
            self.displayedFrame = pixelBuffer
            self.contentLayer.contents = surfaceRef
            self.acceptFirstFrameIfNeeded()
        }
    }

    private func acceptFirstFrameIfNeeded() {
        guard firstFrameDeadline != nil else { return }
        firstFrameDeadline?.invalidate()
        firstFrameDeadline = nil
        send(.frameReceived)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        wplog("overlay: stream stopped wid=\(targetWindowID): \(error)")
        let from = ObjectIdentifier(stream)
        DispatchQueue.main.async { [weak self] in
            // A stream stopped on purpose can report an error on its way out;
            // that is not a reason to restart the one that replaced it.
            guard let self, self.isCurrent(from) else { return }
            self.stream = nil
            // Window may have closed (tracker will prune it), or capture broke
            // (display reconfigure) — retry while we're still pinned-visible.
            self.send(.streamFailed)
        }
    }
}
