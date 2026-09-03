import Foundation
import Observation

// Finds the dev servers an agent's terminal talks about — "Local:
// http://localhost:5173/", "listening on 127.0.0.1:3000", "http://[::1]:8080"
// — so the Preview button can light up at zero cost to the computer. Pure
// text, no network: the host confirms a port only when the person taps.
enum LocalhostPortScanner {
    // Newest mention first, each port once. The pattern: a loopback name
    // with a port, scheme optional; `0.0.0.0` is how Vite's `--host` prints
    // and it answers on loopback too.
    static func scan(_ text: String) -> [Int] {
        guard !text.isEmpty else { return [] }
        var ports: [Int] = []
        var seen = Set<Int>()
        let pattern = #/(?:https?://)?(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]):(?<port>\d{1,5})(?!\d|\.\d)/#
        for match in text.matches(of: pattern).reversed() {
            guard let port = Int(match.output.port), (1...65_535).contains(port), !seen.contains(port) else { continue }
            seen.insert(port)
            ports.append(port)
        }
        return ports
    }
}

// What the Preview button reads while a terminal is open. The transcript
// republishes 4x/s, so the scan is debounced, runs off the main thread, and
// publishes only when the ports themselves change (#68 phone 1).
@MainActor
@Observable
final class MentionedPorts {
    private(set) var ports: [Int] = []

    private static let debounce: Duration = .seconds(2)
    private var task: Task<Void, Never>?

    // One regex over one transcript, replaced by the next transcript and
    // dropped with the terminal: nothing outlives the screen that asked.
    func update(from transcript: String) {
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            let scanned = await Task.detached(priority: .utility) { LocalhostPortScanner.scan(transcript) }.value
            guard !Task.isCancelled, let self, scanned != ports else { return }
            ports = scanned
        }
    }

    func clear() {
        task?.cancel()
        task = nil
        ports = []
    }
}
