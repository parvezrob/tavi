import Foundation

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
            guard let port = Int(match.output.port), (1 ... 65_535).contains(port), !seen.contains(port) else { continue }
            seen.insert(port)
            ports.append(port)
        }
        return ports
    }

}
