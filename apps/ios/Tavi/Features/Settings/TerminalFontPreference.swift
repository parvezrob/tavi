import Foundation
import UIKit

// The user's terminal font size (#51). One number, persisted per phone:
// Settings' slider and the terminal's pinch write the same value, so what
// you pinch is what you keep. The trade-off it controls is the user's to
// make — a smaller font means more columns and rows, which also gives the
// Mac a bigger herdr pane while the phone is attached (#44).
enum TerminalFontPreference {
    static let range: ClosedRange<Double> = 8...24
    static let step: Double = 0.5
    // Ghostty's own default for non-macOS platforms (config font-size = 12),
    // so an untouched setting renders exactly today's size.
    static let defaultSize: Double = 12

    private static let sizeKey = "tavi.terminal.fontSize"

    static func current(in defaults: UserDefaults = .standard) -> Double {
        let stored = defaults.double(forKey: sizeKey)
        return stored > 0 ? clamp(stored) : defaultSize
    }

    static func save(_ size: Double, in defaults: UserDefaults = .standard) {
        defaults.set(clamp(size), forKey: sizeKey)
    }

    // Back to the default, for the DEBUG reset UI tests launch with: a size
    // persisted by one test run must never leak into the next.
    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: sizeKey)
    }

    // Bounded and snapped to half-point steps: Ghostty accepts fractional
    // sizes, but free-floating pinch values would make the slider, the
    // readout, and VoiceOver announce noise like "13.274 points".
    static func clamp(_ size: Double) -> Double {
        let bounded = min(max(size, range.lowerBound), range.upperBound)
        return (bounded / step).rounded() * step
    }

    static func label(for size: Double) -> String {
        size.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(size))
            : String(format: "%.1f", size)
    }
}

// The real terminal's last layout in points, remembered so Settings can
// project the grid a font size yields without opening a terminal: its
// preview surface is laid out at exactly this size and reports the same
// columns × rows the real terminal would.
struct TerminalViewportRecord: Codable, Equatable {
    let width: Double
    let height: Double

    private static let key = "tavi.terminal.viewport"

    func save(in defaults: UserDefaults = .standard) {
        guard width > 0, height > 0 else { return }
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key)
        }
    }

    static func load(in defaults: UserDefaults = .standard) -> TerminalViewportRecord? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(TerminalViewportRecord.self, from: data)
    }

    static func clear(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    // Before any terminal has opened on this phone the exact viewport is
    // unknown; estimate it as the screen minus the terminal chrome (banner,
    // key row, composer). The first real terminal layout replaces this.
    @MainActor
    static func loadOrEstimate(in defaults: UserDefaults = .standard) -> CGSize {
        if let record = load(in: defaults) {
            return CGSize(width: record.width, height: record.height)
        }
        let screen = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.bounds.size }
            .first ?? CGSize(width: 390, height: 844)
        return CGSize(width: screen.width, height: max(screen.height - 280, 200))
    }
}
