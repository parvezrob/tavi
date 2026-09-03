import Foundation
import GhosttyKit
import os
import UIKit

// The bytes between Ghostty and the pane: the callback Ghostty writes into,
// and the pump that feeds it back. Internal rather than file-private only
// because the surface view they serve lives in the file beside this one
// (#100).
// Ghostty owns the callback invocation thread. NSLock protects the bounded byte
// buffer and scheduling flag; one main-actor drain preserves callback order.
final class GhosttyWriteCallback: @unchecked Sendable {
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
// background queue keeps VT parsing (and the grid read behind the
// accessibility transcript) out of the main thread's way, so keyboard and
// touch handling stay responsive during agent redraw storms.
// The invariant `@unchecked Sendable` rests on: after init, every stored property below is read and written only on `queue`, and the `…OnQueue` suffix marks the methods that already run there.
final class GhosttyOutputPump: @unchecked Sendable {
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
    // The last screen text handed out; an unchanged screen is not re-published.
    private var publishedTranscript = ""
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

    // A reflow (resize, font change) changes the screen without new bytes.
    func requestTranscriptPublish() {
        queue.async { [self] in
            guard surface != nil else { return }
            schedulePublishOnQueue()
        }
    }

    // Reads the rendered grid (GhosttyScreenText, #71) at most every 250 ms
    // of output and publishes it when it changed.
    private func schedulePublishOnQueue() {
        guard !transcriptPublishScheduled else { return }
        transcriptPublishScheduled = true
        queue.asyncAfter(deadline: .now() + Self.transcriptPublishDelay) { [self] in
            transcriptPublishScheduled = false
            guard let surface else { return }
            let value = GhosttyScreenText.activeArea(of: surface)
            guard !value.isEmpty, value != publishedTranscript else { return }
            publishedTranscript = value
            let publish = publishTranscript
            Task { @MainActor in
                publish(value)
            }
        }
    }
}

func ghosttySurfaceWrite(
    _ userdata: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<UInt8>?,
    _ count: Int
) {
    guard let userdata, let bytes, count > 0 else { return }
    // Unretained, and safe only while the surface still holds the pointer: the view keeps `callback` alive and clears it in shutdown() before ghostty_surface_free.
    let callback = Unmanaged<GhosttyWriteCallback>
        .fromOpaque(userdata)
        .takeUnretainedValue()
    callback.dispatch(Data(bytes: bytes, count: count))
}
