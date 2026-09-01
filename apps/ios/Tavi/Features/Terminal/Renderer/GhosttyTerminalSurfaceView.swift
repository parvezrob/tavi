import Foundation
import GhosttyKit
import os
import UIKit

struct TerminalGridSize: Sendable, Equatable {
    let columns: Int
    let rows: Int
}

// Ghostty owns the callback invocation thread. NSLock protects the bounded byte
// buffer and scheduling flag; one main-actor drain preserves callback order.
private final class GhosttyWriteCallback: @unchecked Sendable {
    private enum PendingItem {
        case data(Data)
        case overflow
    }

    private static let maximumPendingBytes = 64 * 1_024

    private let handler: @MainActor @Sendable (Data) -> Void
    private let failureHandler: @MainActor @Sendable (String) -> Void
    private let lock = NSLock()
    private var active = true
    private var drainScheduled = false
    private var overflowed = false
    private var pendingData = Data()

    init(
        handler: @escaping @MainActor @Sendable (Data) -> Void,
        failureHandler: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.handler = handler
        self.failureHandler = failureHandler
    }

    nonisolated func dispatch(_ data: Data) {
        lock.lock()
        guard active else {
            lock.unlock()
            return
        }
        if data.count > Self.maximumPendingBytes - pendingData.count {
            pendingData.removeAll(keepingCapacity: false)
            overflowed = true
        } else {
            pendingData.append(data)
        }
        let shouldSchedule = !drainScheduled
        drainScheduled = true
        lock.unlock()

        if shouldSchedule {
            Task { @MainActor [weak self] in
                self?.drainNext()
            }
        }
    }

    nonisolated func cancel() {
        lock.lock()
        active = false
        pendingData.removeAll(keepingCapacity: false)
        overflowed = false
        lock.unlock()
    }

    @MainActor
    private func drainNext() {
        guard let item = takePendingItem() else { return }
        switch item {
        case let .data(data):
            handler(data)
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.drainNext()
            }
        case .overflow:
            failureHandler("Terminal input exceeded Tavi's safety buffer.")
        }
    }

    private nonisolated func takePendingItem() -> PendingItem? {
        lock.lock()
        defer { lock.unlock() }
        guard active else {
            drainScheduled = false
            return nil
        }
        if overflowed {
            active = false
            overflowed = false
            drainScheduled = false
            return .overflow
        }
        guard !pendingData.isEmpty else {
            drainScheduled = false
            return nil
        }
        let data = pendingData
        pendingData.removeAll(keepingCapacity: true)
        return .data(data)
    }
}

// Ghostty's feed path locks renderer state internally and upstream drives it
// from a dedicated IO thread, never the UI thread. Feeding from a serial
// background queue keeps VT parsing (and the accessibility transcript's
// second pass over every byte) out of the main thread's way, so keyboard and
// touch handling stay responsive during agent redraw storms.
private final class GhosttyOutputPump: @unchecked Sendable {
    // Ghostty's feed path and its render thread share one unfair lock, so
    // feeding chunk-after-chunk with no gap can starve rendering entirely.
    // Coalescing pending bytes and feeding at most once per interval keeps
    // the lock free long enough for frames to draw during output storms,
    // while a lone keystroke echo still feeds immediately.
    private static let drainInterval: DispatchTimeInterval = .milliseconds(4)
    // Ghostty's embedded surface does not present new frames on its own; the
    // embedder must call ghostty_surface_draw after content changes (this is
    // what every working draw path in the app already did via resize). The
    // pump therefore drives presentation: refresh after each drain, then a
    // draw paced near display rate, with a small lead so the render thread
    // has ingested the refreshed frame first.
    private static let drawDelay: DispatchTimeInterval = .milliseconds(8)
    private static let drawInterval: DispatchTimeInterval = .milliseconds(16)
    private static let transcriptPublishDelay: DispatchTimeInterval = .milliseconds(250)

    private let queue = DispatchQueue(label: "tavi.terminal.output", qos: .userInitiated)
    private let publishTranscript: @MainActor @Sendable (String) -> Void
    private var surface: ghostty_surface_t?
    private var transcript = TerminalAccessibleTranscript()
    private var transcriptPublishScheduled = false
    private var pendingData = Data()
    private var drainScheduled = false
    private var lastDrainAt = DispatchTime(uptimeNanoseconds: 0)
    private var drawScheduled = false
    private var drawSuspended = false
    private var lastDrawAt = DispatchTime(uptimeNanoseconds: 0)

    init(
        surface: ghostty_surface_t,
        publishTranscript: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.surface = surface
        self.publishTranscript = publishTranscript
    }

    func feed(_ data: Data) {
        queue.async { [self] in
            guard surface != nil else { return }
            pendingData.append(data)
            scheduleDrainOnQueue()
        }
    }

    private func scheduleDrainOnQueue() {
        guard !drainScheduled else { return }
        drainScheduled = true
        let earliest = lastDrainAt + Self.drainInterval
        if earliest < .now() {
            drainOnQueue()
        } else {
            queue.asyncAfter(deadline: earliest) { [self] in
                drainOnQueue()
            }
        }
    }

    private func drainOnQueue() {
        drainScheduled = false
        lastDrainAt = .now()
        guard let surface, !pendingData.isEmpty else { return }
        let data = pendingData
        pendingData.removeAll(keepingCapacity: true)
        data.withUnsafeBytes { rawBuffer in
            guard let address = rawBuffer.baseAddress else { return }
            ghostty_surface_feed_data(
                surface,
                address.assumingMemoryBound(to: UInt8.self),
                rawBuffer.count
            )
        }
        ghostty_surface_refresh(surface)
        scheduleDrawOnQueue()
        transcript.append(data)
        schedulePublishOnQueue()
    }

    private func scheduleDrawOnQueue() {
        guard !drawScheduled, !drawSuspended else { return }
        drawScheduled = true
        let earliest = max(lastDrawAt + Self.drawInterval, .now() + Self.drawDelay)
        queue.asyncAfter(deadline: earliest) { [self] in
            drawOnQueue()
        }
    }

    private func drawOnQueue() {
        drawScheduled = false
        lastDrawAt = .now()
        guard let surface, !drawSuspended else { return }
        ghostty_surface_draw(surface)
    }

    // Blocks until any in-flight chunk finishes and drops the surface so the
    // caller can free it safely afterwards. Chunks still queued become no-ops.
    func shutdown() {
        queue.sync { surface = nil }
    }

    // Draws from a background app get processes killed by iOS, so the surface
    // view pauses pump-driven drawing while it is inactive.
    func setDrawingSuspended(_ suspended: Bool) {
        queue.async { [self] in
            drawSuspended = suspended
            if !suspended, surface != nil {
                scheduleDrawOnQueue()
            }
        }
    }

    private func schedulePublishOnQueue() {
        guard !transcriptPublishScheduled else { return }
        transcriptPublishScheduled = true
        queue.asyncAfter(deadline: .now() + Self.transcriptPublishDelay) { [self] in
            transcriptPublishScheduled = false
            guard surface != nil, !transcript.isEmpty else { return }
            let value = transcript.value
            let publish = publishTranscript
            Task { @MainActor in
                publish(value)
            }
        }
    }
}

private func ghosttySurfaceWrite(
    _ userdata: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<UInt8>?,
    _ count: Int
) {
    guard let userdata, let bytes, count > 0 else { return }
    let callback = Unmanaged<GhosttyWriteCallback>
        .fromOpaque(userdata)
        .takeUnretainedValue()
    callback.dispatch(Data(bytes: bytes, count: count))
}

@MainActor
final class GhosttyTerminalSurfaceView: UIView, UIKeyInput {
    private static let logger = Logger(subsystem: "com.farfield.tavi", category: "terminal.surface")

    var onGridSizeChange: ((TerminalGridSize) -> Void)?
    // Set by the real terminal only (#51): a pinch that settles is saved as
    // the one font size preference. The Settings preview leaves this nil,
    // which also disables its pinch entirely.
    var onFontSizeCommit: ((Double) -> Void)?
    // The Settings preview renders but must never pop the keyboard or
    // record its (clipped, off-screen-sized) layout as the real viewport.
    var acceptsKeyboardFocus = true
    var recordsViewport = false

    var hasText: Bool { true }
    // The standard iOS keyboard, with only the text-rewriting features off:
    // autocorrect and smart punctuation silently corrupt shell commands.
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var returnKeyType: UIReturnKeyType = .default
    var enablesReturnKeyAutomatically = false
    var isSecureTextEntry = false

    override var canBecomeFirstResponder: Bool { acceptsKeyboardFocus }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(sendEscape)),
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(sendTab)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(sendUpArrow)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(sendDownArrow)),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(sendLeftArrow)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(sendRightArrow)),
            UIKeyCommand(input: "c", modifierFlags: .control, action: #selector(sendInterrupt)),
        ]
    }

    private let callback: GhosttyWriteCallback
    private let inputHandler: @MainActor (Data) -> Void
    private(set) var fontSize: Double
    private var keyboardObservers: [NSObjectProtocol] = []
    private var keyboardVisible = false
    private var lastGridSize: TerminalGridSize?
    private var pinchBaseFontSize: Double = 0
    // While a pinch is in flight the surface re-renders on every step, but
    // the grid is published once, on release: publishing each 0.5-pt step
    // would queue a pty resize per step and thrash the Mac pane through a
    // dozen re-flows per gesture.
    private var pinchInFlight = false
    private var outputPump: GhosttyOutputPump?
    // Scrolling state (#10). One display link runs for the whole of a drag and
    // its momentum; Ghostty is fed as touches arrive, but the surface is drawn
    // at most once per frame from the link.
    private var scrollLink: CADisplayLink?
    private var scrollMomentumVelocity: CGFloat = 0
    private var scrollMomentumActive = false
    private var scrollDragActive = false
    private var scrollDrawPending = false
    private var surface: ghostty_surface_t?

    init(
        runtime: GhosttyRuntime,
        fontSize: Double,
        onInput: @escaping @MainActor (Data) -> Void,
        onFailure: @escaping @MainActor (String) -> Void
    ) throws {
        callback = GhosttyWriteCallback(handler: onInput, failureHandler: onFailure)
        inputHandler = onInput
        self.fontSize = TerminalFontPreference.clamp(fontSize)
        super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

        isAccessibilityElement = true
        accessibilityIdentifier = "terminal.surface"
        accessibilityLabel = "Remote terminal"
        accessibilityHint = "Double tap to type in the remote terminal"
        accessibilityValue = "No terminal output yet"
        accessibilityTraits.insert(.updatesFrequently)
        backgroundColor = .black
        isOpaque = true

        let focusGesture = UITapGestureRecognizer(target: self, action: #selector(focusKeyboard))
        focusGesture.cancelsTouchesInView = false
        addGestureRecognizer(focusGesture)

        let scrollGesture = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        scrollGesture.maximumNumberOfTouches = 1
        addGestureRecognizer(scrollGesture)

        // Pinch adjusts the same persisted font size Settings shows (#51):
        // what you pinch is what you keep, never a transient zoom.
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handleFontPinch(_:))))

        var configuration = ghostty_surface_config_new()
        configuration.platform_tag = GHOSTTY_PLATFORM_IOS
        configuration.platform = ghostty_platform_u(
            ios: ghostty_platform_ios_s(
                uiview: Unmanaged.passUnretained(self).toOpaque()
            )
        )
        configuration.userdata = Unmanaged.passUnretained(self).toOpaque()
        configuration.scale_factor = traitCollection.displayScale
        configuration.font_size = Float(self.fontSize)
        configuration.use_custom_io = true

        guard let surface = ghostty_surface_new(runtime.app, &configuration) else {
            throw GhosttyRuntimeError.appCreationFailed
        }
        self.surface = surface
        outputPump = GhosttyOutputPump(surface: surface) { [weak self] transcriptValue in
            self?.accessibilityValue = transcriptValue
        }
        ghostty_surface_set_write_callback(
            surface,
            ghosttySurfaceWrite,
            Unmanaged.passUnretained(callback).toOpaque()
        )

        // Keyboard show/hide changes the usable terminal area, but the
        // resulting SwiftUI layout pass does not reliably reach
        // layoutSubviews on every transition. An explicit resize pass after
        // each keyboard settle guarantees the grid is recomputed on both
        // edges; the grid guard in resizeSurface dedupes no-op passes.
        // keyboardVisible additionally flips on willShow so the layout
        // passes between willShow and didShow are already marked as
        // keyboard-up and never recorded as the terminal's viewport.
        keyboardObservers.append(NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillShowNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.keyboardVisible = true
            }
        })
        for name in [UIResponder.keyboardDidShowNotification, UIResponder.keyboardDidHideNotification] {
            keyboardObservers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let keyboardVisible = notification.name == UIResponder.keyboardDidShowNotification
                MainActor.assumeIsolated {
                    self?.keyboardVisible = keyboardVisible
                    self?.keyboardDidSettle()
                }
            })
        }
    }

    private func keyboardDidSettle() {
        guard surface != nil else { return }
        superview?.setNeedsLayout()
        superview?.layoutIfNeeded()
        resizeSurface()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override class var layerClass: AnyClass {
        CALayer.self
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        resizeSurface()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for sublayer in layer.sublayers ?? [] {
            sublayer.frame = bounds
            sublayer.contentsScale = contentScaleFactor
        }
        resizeSurface()
    }

    func insertText(_ text: String) {
        let terminalText = text
            .replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        inputHandler(Data(terminalText.utf8))
    }

    func deleteBackward() {
        inputHandler(Data([0x7F]))
    }

    @objc func focusKeyboard() {
        guard acceptsKeyboardFocus else { return }
        becomeFirstResponder()
    }

    // Applies a font size through Ghostty's own keybind action, which
    // re-flows the grid synchronously (the cell size is assigned before
    // the action returns — verified in the vendored Surface.setFontSize);
    // the pty resize then follows through onGridSizeChange exactly as a
    // rotation or keyboard change would.
    func setFontSize(_ points: Double) {
        guard let surface else { return }
        let target = TerminalFontPreference.clamp(points)
        guard target != fontSize else { return }
        // The action string is Ghostty wire format, never user-facing: it
        // must always use "." regardless of locale, so it is built from
        // non-localizing conversions only.
        let argument = target.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(target))
            : String(target)
        let action = "set_font_size:\(argument)"
        let applied = action.withCString { pointer in
            ghostty_surface_binding_action(surface, pointer, UInt(action.utf8.count))
        }
        guard applied else {
            Self.logger.error("font size action rejected: \(action)")
            return
        }
        fontSize = target
        ghostty_surface_refresh(surface)
        ghostty_surface_draw(surface)
        if !pinchInFlight {
            publishGridSize()
        }
    }

    @objc private func handleFontPinch(_ gesture: UIPinchGestureRecognizer) {
        guard onFontSizeCommit != nil else { return }
        switch gesture.state {
        case .began:
            pinchBaseFontSize = fontSize
            pinchInFlight = true
        case .changed:
            setFontSize(pinchBaseFontSize * Double(gesture.scale))
        case .ended, .cancelled, .failed:
            // What you pinch is what you keep — a cancelled gesture has
            // already re-rendered, so it commits too rather than silently
            // reverting on the next open.
            pinchInFlight = false
            publishGridSize()
            onFontSizeCommit?(fontSize)
        default:
            break
        }
    }

    // Touch scrolling maps finger drags to Ghostty's precision scroll input,
    // with momentum after release. Two things make it feel like a native list
    // (#10): Ghostty's precision `yoff` is in *pixels* (its cell height is
    // DPI-scaled — upstream's AppKit view has the same open TODO), so points
    // are multiplied by the content scale or a 3× phone scrolls at a third of
    // finger speed in visible row jumps; and drawing happens once per display
    // frame from a display link rather than synchronously on every touch
    // sample, so a 120 Hz drag never queues more draws than frames.
    @objc private func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopScrollMomentum()
            scrollDragActive = true
            updateMousePosition(gesture.location(in: self))
            startScrollLink()
        case .changed:
            updateMousePosition(gesture.location(in: self))
            let translation = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            feedScroll(pointsY: translation.y, momentum: GHOSTTY_MOUSE_MOMENTUM_NONE)
        case .ended:
            scrollDragActive = false
            startScrollMomentum(velocity: gesture.velocity(in: self).y)
        case .cancelled, .failed:
            scrollDragActive = false
            stopScrollMomentum()
        default:
            break
        }
    }

    // Ghostty drops mouse reports whose cursor position was never set (the
    // embedded default is off-viewport), so the position must be fed before
    // scroll events for mouse-wheel reporting to a TUI in mouse mode to work.
    private func updateMousePosition(_ location: CGPoint) {
        guard let surface else { return }
        ghostty_surface_mouse_pos(surface, Double(location.x), Double(location.y), GHOSTTY_MODS_NONE)
    }

    // Momentum is packed into the scroll mods exactly as upstream's AppKit
    // view does: bit 0 = precision, bits 1… = the momentum phase.
    private func feedScroll(pointsY: CGFloat, momentum: ghostty_input_mouse_momentum_e) {
        guard let surface, pointsY != 0 else { return }
        let scale = contentScaleFactor > 0 ? contentScaleFactor : traitCollection.displayScale
        let mods: Int32 = 1 | Int32(momentum.rawValue) << 1
        ghostty_surface_mouse_scroll(surface, 0, Double(pointsY * scale), mods)
        scrollDrawPending = true
    }

    private func startScrollLink() {
        guard scrollLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(stepScroll(_:)))
        // Ask for the panel's full rate: a scroll is the one interaction
        // where frame pacing is the whole experience.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        scrollLink = link
    }

    // Deceleration matches UIScrollView's normal rate (0.998 per millisecond),
    // applied per elapsed time so 60 Hz and 120 Hz panels coast the same
    // distance instead of the old per-frame factor stopping twice as fast on
    // ProMotion.
    private static let momentumDecelerationPerMillisecond = UIScrollView.DecelerationRate.normal.rawValue
    private static let momentumStartThreshold: CGFloat = 80
    private static let momentumStopThreshold: CGFloat = 20

    private func startScrollMomentum(velocity: CGFloat) {
        scrollMomentumVelocity = 0
        scrollMomentumActive = false
        // Below the threshold the link still flushes the last drag sample,
        // then retires itself.
        guard abs(velocity) > Self.momentumStartThreshold else { return }
        scrollMomentumVelocity = velocity
        scrollMomentumActive = true
        startScrollLink()
    }

    @objc private func stepScroll(_ link: CADisplayLink) {
        if scrollMomentumActive {
            let elapsed = max(0, link.targetTimestamp - link.timestamp)
            let decay = pow(Self.momentumDecelerationPerMillisecond, elapsed * 1000)
            let distance = scrollMomentumVelocity * CGFloat(elapsed)
            scrollMomentumVelocity *= CGFloat(decay)
            if abs(scrollMomentumVelocity) <= Self.momentumStopThreshold {
                scrollMomentumActive = false
                scrollMomentumVelocity = 0
                feedScroll(pointsY: distance, momentum: GHOSTTY_MOUSE_MOMENTUM_ENDED)
            } else {
                feedScroll(pointsY: distance, momentum: GHOSTTY_MOUSE_MOMENTUM_CHANGED)
            }
        }
        if scrollDrawPending, let surface {
            scrollDrawPending = false
            ghostty_surface_refresh(surface)
            ghostty_surface_draw(surface)
        }
        if !scrollMomentumActive, !scrollDrawPending, !scrollDragActive {
            stopScrollLink()
        }
    }

    private func stopScrollMomentum() {
        scrollMomentumActive = false
        scrollMomentumVelocity = 0
        // Draw whatever was fed, then let the link retire itself.
        if scrollDrawPending { startScrollLink() }
    }

    private func stopScrollLink() {
        scrollLink?.invalidate()
        scrollLink = nil
    }

    func dismissKeyboard() {
        resignFirstResponder()
    }

    func receive(_ data: Data) {
        guard surface != nil, !data.isEmpty else { return }
        outputPump?.feed(data)
    }

    func setActive(_ active: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, active)
        ghostty_surface_set_occlusion(surface, !active)
        outputPump?.setDrawingSuspended(!active)
        if active {
            ghostty_surface_refresh(surface)
            ghostty_surface_draw(surface)
        }
    }

    func shutdown() {
        guard let surface else { return }
        self.surface = nil
        onGridSizeChange = nil
        scrollMomentumActive = false
        scrollDragActive = false
        scrollDrawPending = false
        stopScrollLink()
        keyboardObservers.forEach(NotificationCenter.default.removeObserver)
        keyboardObservers.removeAll()
        resignFirstResponder()
        ghostty_surface_set_focus(surface, false)
        ghostty_surface_set_occlusion(surface, true)
        callback.cancel()
        ghostty_surface_set_write_callback(surface, nil, nil)
        outputPump?.shutdown()
        outputPump = nil
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        ghostty_surface_free(surface)
    }

    isolated deinit {
        if surface != nil {
            assertionFailure("Ghostty surface must be shut down before deinitialization.")
        }
    }

    private func resizeSurface() {
        guard let surface, bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.screen.scale ?? traitCollection.displayScale
        contentScaleFactor = scale
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(
            surface,
            UInt32(bounds.width * scale),
            UInt32(bounds.height * scale)
        )
        ghostty_surface_refresh(surface)
        ghostty_surface_draw(surface)

        // Only the real terminal's layout is the viewport Settings projects
        // grids from; the preview's own frame must never overwrite it, and
        // neither must a keyboard-up layout — that would make Settings
        // project rows against half the screen and present it as fact.
        if recordsViewport, !keyboardVisible {
            TerminalViewportRecord(width: bounds.width, height: bounds.height).save()
        }
        publishGridSize()
    }

    // Reads the surface's current grid and reports a change. Runs after
    // anything that can re-flow it: a resize or a font size change.
    private func publishGridSize() {
        guard let surface else { return }
        let size = ghostty_surface_size(surface)
        let grid = TerminalGridSize(columns: Int(size.columns), rows: Int(size.rows))
        Self.logger.info(
            "grid \(grid.columns)x\(grid.rows) bounds=\(self.bounds.width, format: .fixed(precision: 0))x\(self.bounds.height, format: .fixed(precision: 0)) font=\(self.fontSize) last=\(String(describing: self.lastGridSize))"
        )
        guard grid.columns > 0, grid.rows > 0, grid != lastGridSize else { return }
        lastGridSize = grid
        onGridSizeChange?(grid)
    }

    @objc private func sendEscape() {
        sendKey(.escape)
    }

    @objc private func sendTab() {
        sendKey(.tab)
    }

    @objc private func sendUpArrow() {
        sendKey(.up)
    }

    @objc private func sendDownArrow() {
        sendKey(.down)
    }

    @objc private func sendLeftArrow() {
        sendKey(.left)
    }

    @objc private func sendRightArrow() {
        sendKey(.right)
    }

    @objc private func sendInterrupt() {
        sendKey(.interrupt)
    }

    private func sendKey(_ key: TerminalQuickKey) {
        inputHandler(Data(key.sequence.utf8))
    }
}
