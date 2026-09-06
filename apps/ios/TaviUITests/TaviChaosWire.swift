import Foundation

// The chaos host's HTTP contract, the phone's diagnostics element, and the
// few values the run collects (#111). Times are milliseconds since the Unix
// epoch on both sides. Kept beside the soak rather than inside it so the
// contract is one readable page.

// MARK: - The budgets

// The plan's numbers in one place. `terminalDelay` and `eventsDelay` are
// copies of `ReconnectPolicy.terminalDefault` (250 ms → 8 s, ×2) and the
// events schedule in `HostConnection` (2 s → 10 s, ×2): a UI-test bundle
// cannot `@testable import Tavi`, so they are duplicated here and read as the
// jitter-free upper bound — production multiplies by 80–100 %.
enum ChaosBudget {
    // A fault is requested only once the counters show this much health.
    static let liveBeforeFault: Double = 30
    // terminate / closeMidOutput on the terminal, at attempt 1: 0.25 s + a 4 s dial.
    static let terminalLiveAgainAtFirstAttempt: Double = 4.5
    static let terminalReadyDeadline: Double = 12
    static let terminalBlackholeMs = 30_000
    // A round may be awaiting its send completion for 5 s when the pause
    // begins, then ≤ 10 s to the next beat + 5 s send + 5 s pong.
    static let terminalBlackholeDetection: Double = 25
    static let terminalBlackholeLiveAgain: Double = 30
    static let slowReadyMs = 6_000
    // Past the 45–50 s watchdog boundary, so the cycle is unambiguous.
    static let eventsBlackholeMs = 70_000
    static let eventsWatchdogCycle: Double = 50
    static let eventsLiveAgainAfterDial: Double = 4
    static let hostPauseMs = 70_000
    // Tolerances for asynchronous publication, not budgets.
    static let healthWindow: Double = 5
    static let samplerAllowance: Double = 2
    static let freshness: Double = 3

    static func terminalDelay(_ attempt: Int) -> Double {
        min(0.25 * pow(2, Double(max(1, attempt) - 1)), 8)
    }

    static func eventsDelay(_ attempt: Int) -> Double {
        min(2 * pow(2, Double(max(1, attempt) - 1)), 10)
    }
}

// MARK: - What the run collects

// A fault this run requested, under the name the numbers report it by: the
// wire kind alone cannot tell `terminate` from `terminate + slowReady`.
struct FiredFault {
    let name: String
    let id: String
    let at: Double
    let socket: String
    let thenSlowReadyMs: Int?
    // The contrast is proved by its own assertions, not by a recovery budget.
    let scoredForRecovery: Bool
}

struct Mark {
    enum Window: String {
        case healthy
        case beforeFault
    }

    let number: Int
    let window: Window
    let at: Double
}

struct Sample {
    let at: Double
    let terminalIsLive: Bool
    let status: String?
    let surface: String
    let health: String?
}

struct HealthPoll {
    let at: Double
    let answered: Bool
}

struct Distribution {
    let count: Int
    let min: Double
    let median: Double
    let max: Double

    init(_ values: [Double]) {
        let sorted = values.sorted()
        count = sorted.count
        min = sorted.first ?? 0
        max = sorted.last ?? 0
        median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    var asJSON: [String: Any] { ["n": count, "min": min, "median": median, "max": max] }
}

// MARK: - The chaos host

struct FaultRequest: Encodable {
    let kind: String
    let socket: String
    var paneId: String?
    var ms: Int?
    var code: Int?
    var thenSlowReadyMs: Int?
}

struct FaultAck: Decodable {
    let id: String
    let at: Double
}

struct ChaosFaultRecord: Decodable {
    let id: String
    let at: Double
    let kind: String
    let socket: String
    let paneId: String?
    let ms: Int?
    let code: Int?
    let thenSlowReadyMs: Int?
    // Set on the fault whose `thenSlowReadyMs` the next attach consumed.
    let consumedByAttachAt: Double?
}

struct ChaosFaultList: Decodable {
    let events: [ChaosFaultRecord]
}

struct ChaosAttachment: Decodable {
    let paneId: String
    let stream: String
    let startOffset: UInt64
    // The next offset the host will write; the phone's accepted offset must
    // equal it at the checkpoint.
    let endOffset: UInt64
    let claims: Int
    let resumeHits: Int
    let resumeMisses: Int
    let supersedes: Int
    let lastReadyOffset: UInt64
    let releasedAt: Double?
    let resizedAt: Double?
}

struct ChaosAttachmentList: Decodable {
    let attachments: [ChaosAttachment]
}

// MARK: - The phone

// Exactly the shape `RecoveryLog.diagnosticsLine` publishes.
struct DiagnosticsCounters: Decodable {
    let dials: Int
    let readies: Int
    let resumeHits: Int
    let resumeMisses: Int
    let resumeMismatches: Int
    let offsetGaps: Int?
    let offsetOverlaps: Int?
    let outputDiscarded: Int?
    let acceptedOffset: UInt64?
    let cycles: [String: Int]
    let offlineEntered: Int?
    let offlineCleared: Int?
}

struct DiagnosticsEvent: Decodable {
    let at: Int
    let monotonic: Int
    let source: String
    let kind: String
    let reason: String
    let generation: Int
    let attempt: Int
    let elapsedMs: Int
    let resumed: Bool?
    let pathSatisfied: Bool?
}

struct DiagnosticsLine: Decodable {
    let host: String
    let terminal: DiagnosticsCounters
    let events: DiagnosticsCounters
    let ring: [DiagnosticsEvent]
}

// MARK: - What the run is made of

struct ChaosEnvironment {
    let live: LiveEnvironment
    let minutes: Int

    var host: String { live.host }
    var token: String { live.token }
}

enum ChaosSoakFailure: Error {
    case diagnosticsUnreadable
    case faultRefused
    case routeUnavailable
    case fixtureRejected
}

enum TerminalFault: CaseIterable {
    case terminate
    case blackhole
    case slowReady
    case closeMidOutput1011
    case closeMidOutput1001
    case takeover

    // How much of the phase this fault needs to be worth firing: its own
    // recovery budget with room to see it, so an overrun costs one fault
    // rather than compounding into the next.
    var needsSeconds: TimeInterval {
        switch self {
        case .takeover: 150
        case .blackhole: 90
        default: 60
        }
    }
}

enum EventsFault: CaseIterable {
    case terminate
    case blackhole
    case closeMidOutput1001
    case hostPauseContrast
}

// One healthy stretch of one source: what has already been typed into it.
struct CycleState {
    var readyAt: Double?
    var markedHealthy = false
    var firedFault = false
}
