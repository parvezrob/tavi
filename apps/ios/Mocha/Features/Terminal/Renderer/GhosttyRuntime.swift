import Foundation
import GhosttyKit

enum GhosttyRuntimeError: Error, LocalizedError {
    case appCreationFailed
    case configurationCreationFailed
    case initializationFailed

    var errorDescription: String? {
        switch self {
        case .appCreationFailed:
            "Ghostty could not create its application runtime."
        case .configurationCreationFailed:
            "Ghostty could not create its terminal configuration."
        case .initializationFailed:
            "Ghostty could not initialize."
        }
    }
}

@MainActor
final class GhosttyRuntime {
    static let shared = Result { try GhosttyRuntime() }

    var app: ghostty_app_t { handles.app }
    private let handles: GhosttyHandles

    private init() throws {
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            throw GhosttyRuntimeError.initializationFailed
        }
        guard let configuration = ghostty_config_new() else {
            throw GhosttyRuntimeError.configurationCreationFailed
        }
        ghostty_config_finalize(configuration)
        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: ghosttyRuntimeWakeup,
            action_cb: ghosttyRuntimeAction,
            read_clipboard_cb: ghosttyRuntimeReadClipboard,
            confirm_read_clipboard_cb: ghosttyRuntimeConfirmReadClipboard,
            write_clipboard_cb: ghosttyRuntimeWriteClipboard,
            close_surface_cb: ghosttyRuntimeCloseSurface
        )
        guard let app = ghostty_app_new(&runtime, configuration) else {
            ghostty_config_free(configuration)
            throw GhosttyRuntimeError.appCreationFailed
        }
        handles = GhosttyHandles(app: app, configuration: configuration)
        ghostty_app_set_focus(app, true)
    }

    func tick() {
        ghostty_app_tick(app)
    }

}

private func ghosttyRuntimeWakeup(_ userdata: UnsafeMutableRawPointer?) {
    Task { @MainActor in
        try? GhosttyRuntime.shared.get().tick()
    }
}

private func ghosttyRuntimeAction(
    _ app: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
) -> Bool {
    false
}

private func ghosttyRuntimeReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ clipboard: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    false
}

private func ghosttyRuntimeConfirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ value: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {}

private func ghosttyRuntimeWriteClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ clipboard: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?,
    _ count: Int,
    _ confirm: Bool
) {}

private func ghosttyRuntimeCloseSurface(
    _ userdata: UnsafeMutableRawPointer?,
    _ processAlive: Bool
) {}

// These opaque C handles are created, read, and destroyed only through the
// main-actor-isolated GhosttyRuntime. The wrapper merely gives them one owner.
private final class GhosttyHandles: @unchecked Sendable {
    let app: ghostty_app_t
    let configuration: ghostty_config_t

    init(app: ghostty_app_t, configuration: ghostty_config_t) {
        self.app = app
        self.configuration = configuration
    }

    deinit {
        ghostty_app_free(app)
        ghostty_config_free(configuration)
    }
}
