import Foundation
import Testing
@testable import Tavi

// The connection in words (#86 / #84, PRD §7.13): the host's `connection`
// becomes a suffix on the header and a sentence on the computer sheet.
struct ConnectionPathTests {
    @Test func hostAnswerBecomesAPath() {
        #expect(ConnectionPath(path: "direct", relay: nil) == .direct)
        #expect(ConnectionPath(path: "relay", relay: "blr") == .relay("blr"))
        #expect(ConnectionPath(path: "relay", relay: "") == .relay(nil))
        #expect(ConnectionPath(path: "unknown", relay: nil) == .unknown)
        // An older host sends nothing; a stranger's word is unknown too.
        #expect(ConnectionPath(path: nil, relay: nil) == .unknown)
        #expect(ConnectionPath(path: "hairpin", relay: nil) == .unknown)
    }

    @Test func headerSaysRelayAndNothingElse() {
        #expect(HostHealth.live.label(latencyMilliseconds: 7, connection: .direct) == "Live · 7 ms")
        #expect(HostHealth.live.label(latencyMilliseconds: 40, connection: .relay("blr")) == "Live · 40 ms · relay")
        #expect(HostHealth.live.label(latencyMilliseconds: nil, connection: .relay(nil)) == "Live · relay")
        #expect(HostHealth.live.label(latencyMilliseconds: 7) == "Live · 7 ms")
        // Only a live computer carries the path; the others say their state.
        #expect(HostHealth.stale.label(latencyMilliseconds: 40, connection: .relay("blr")) == "Reconnecting")
        #expect(HostHealth.offline.label(latencyMilliseconds: nil, connection: .relay("blr")) == "Offline")
    }

    @Test func sheetSentencesArePlainAndNeverAlarmed() {
        #expect(ConnectionPath.direct.sentence == "Direct to this computer — the fastest path there is.")
        #expect(ConnectionPath.relay("blr").sentence?.hasPrefix("Through a Tailscale relay (blr) — slower, still private.") == true)
        #expect(ConnectionPath.relay(nil).sentence?.hasPrefix("Through a Tailscale relay — slower, still private.") == true)
        #expect(ConnectionPath.unknown.sentence == nil)
    }
}
