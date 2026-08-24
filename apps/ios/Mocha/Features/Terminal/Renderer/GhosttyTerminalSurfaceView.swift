import Foundation
import GhosttyKit
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
            failureHandler("Terminal input exceeded Mocha's safety buffer.")
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
    var onGridSizeChange: ((TerminalGridSize) -> Void)?

    var hasText: Bool { true }
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var returnKeyType: UIReturnKeyType = .default
    var enablesReturnKeyAutomatically = false
    var isSecureTextEntry = false

    override var canBecomeFirstResponder: Bool { true }

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
    private var accessibleTranscript = TerminalAccessibleTranscript()
    private var lastGridSize: TerminalGridSize?
    private var surface: ghostty_surface_t?

    init(
        runtime: GhosttyRuntime,
        onInput: @escaping @MainActor (Data) -> Void,
        onFailure: @escaping @MainActor (String) -> Void
    ) throws {
        callback = GhosttyWriteCallback(handler: onInput, failureHandler: onFailure)
        inputHandler = onInput
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

        var configuration = ghostty_surface_config_new()
        configuration.platform_tag = GHOSTTY_PLATFORM_IOS
        configuration.platform = ghostty_platform_u(
            ios: ghostty_platform_ios_s(
                uiview: Unmanaged.passUnretained(self).toOpaque()
            )
        )
        configuration.userdata = Unmanaged.passUnretained(self).toOpaque()
        configuration.scale_factor = traitCollection.displayScale
        configuration.use_custom_io = true

        guard let surface = ghostty_surface_new(runtime.app, &configuration) else {
            throw GhosttyRuntimeError.appCreationFailed
        }
        self.surface = surface
        ghostty_surface_set_write_callback(
            surface,
            ghosttySurfaceWrite,
            Unmanaged.passUnretained(callback).toOpaque()
        )
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
        becomeFirstResponder()
    }

    func dismissKeyboard() {
        resignFirstResponder()
    }

    func receive(_ data: Data) {
        guard let surface, !data.isEmpty else { return }
        accessibleTranscript.append(data)
        accessibilityValue = accessibleTranscript.value.isEmpty
            ? "No terminal output yet"
            : accessibleTranscript.value
        data.withUnsafeBytes { rawBuffer in
            guard let address = rawBuffer.baseAddress else { return }
            ghostty_surface_feed_data(
                surface,
                address.assumingMemoryBound(to: UInt8.self),
                rawBuffer.count
            )
        }
    }

    func setActive(_ active: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, active)
        ghostty_surface_set_occlusion(surface, !active)
        if active {
            ghostty_surface_refresh(surface)
            ghostty_surface_draw(surface)
        }
    }

    func shutdown() {
        guard let surface else { return }
        self.surface = nil
        onGridSizeChange = nil
        resignFirstResponder()
        ghostty_surface_set_focus(surface, false)
        ghostty_surface_set_occlusion(surface, true)
        callback.cancel()
        ghostty_surface_set_write_callback(surface, nil, nil)
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

        let size = ghostty_surface_size(surface)
        let grid = TerminalGridSize(columns: Int(size.columns), rows: Int(size.rows))
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
