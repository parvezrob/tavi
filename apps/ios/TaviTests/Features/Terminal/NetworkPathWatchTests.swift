import Foundation
@testable import Tavi
import Testing

// What the path monitor is worth to a connection (#111), through the real
// watch and a scripted observer: the repeats the monitor delivers are the
// noise this type exists to remove.
@MainActor
struct NetworkPathWatchTests {
    private let wifi = NetworkPathSnapshot(isSatisfied: true, interfaceIdentity: "en0")
    private let cellular = NetworkPathSnapshot(isSatisfied: true, interfaceIdentity: "pdp_ip0")
    private let none = NetworkPathSnapshot(isSatisfied: false, interfaceIdentity: "none")

    private func watching(_ paths: ScriptedPathObserver) -> (NetworkPathWatch, Recorder) {
        let watch = NetworkPathWatch(observer: paths)
        let recorder = Recorder()
        watch.start { recorder.events.append($0) }
        return (watch, recorder)
    }

    @MainActor
    private final class Recorder {
        var events: [NetworkPathWatch.Event] = []
    }

    // A connection that starts with no network must not wait for one.
    @Test func anUnsatisfiedFirstSnapshotIsALoss() async throws {
        let paths = ScriptedPathObserver()
        let (watch, recorder) = watching(paths)
        defer { watch.stop() }

        paths.emit(none)
        try await waitFor { recorder.events == [.lost] }
        #expect(watch.current == none)
    }

    // The first satisfied snapshot is only the baseline.
    @Test func aSatisfiedFirstSnapshotIsOnlyTheBaseline() async throws {
        let paths = ScriptedPathObserver()
        let (watch, recorder) = watching(paths)
        defer { watch.stop() }

        paths.emit(wifi)
        try await waitFor { watch.current == self.wifi }
        await settle()
        #expect(recorder.events.isEmpty)
    }

    // The monitor repeats the same snapshot on every unrelated change.
    @Test func aRepeatedSnapshotSaysNothingTwice() async throws {
        let paths = ScriptedPathObserver()
        let (watch, recorder) = watching(paths)
        defer { watch.stop() }

        paths.emit(none)
        try await waitFor { recorder.events == [.lost] }
        paths.emit(none)
        paths.emit(none)
        await settle()
        #expect(recorder.events == [.lost])
    }

    @Test func aNewInterfaceOnASatisfiedPathIsAChange() async throws {
        let paths = ScriptedPathObserver()
        let (watch, recorder) = watching(paths)
        defer { watch.stop() }

        paths.emit(wifi)
        paths.emit(cellular)
        try await waitFor { recorder.events == [.changed(from: self.wifi, to: self.cellular)] }
    }

    @Test func aPathThatComesBackIsRestoredRatherThanChanged() async throws {
        let paths = ScriptedPathObserver()
        let (watch, recorder) = watching(paths)
        defer { watch.stop() }

        paths.emit(none)
        paths.emit(wifi)
        try await waitFor { recorder.events == [.lost, .restored(from: self.none, to: self.wifi)] }
    }

    @Test func aStoppedWatchReportsNothingAndKnowsNothing() async throws {
        let paths = ScriptedPathObserver()
        let (watch, recorder) = watching(paths)

        paths.emit(wifi)
        try await waitFor { watch.current == self.wifi }
        watch.stop()
        #expect(watch.current == nil)

        paths.emit(none)
        await settle()
        #expect(recorder.events.isEmpty)
    }

    // Starting twice must not leave a second monitor running against a
    // closure the caller has replaced.
    @Test func startingTwiceKeepsOneTask() async throws {
        let paths = ScriptedPathObserver()
        let (watch, recorder) = watching(paths)
        defer { watch.stop() }
        let second = Recorder()
        watch.start { second.events.append($0) }

        paths.emit(none)
        try await waitFor { recorder.events == [.lost] }
        await settle()
        #expect(paths.subscriptionCount == 1)
        #expect(second.events.isEmpty)
    }
}
