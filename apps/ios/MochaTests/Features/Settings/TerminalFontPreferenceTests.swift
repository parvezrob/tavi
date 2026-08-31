import Foundation
import Testing
@testable import Mocha

struct TerminalFontPreferenceTests {
    // A throwaway defaults suite that removes its plist when the test ends,
    // so runs never accumulate files in the test host's container.
    private final class ScratchDefaults {
        let name = "test.fontPreference.\(UUID().uuidString)"
        let defaults: UserDefaults

        init() {
            defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
        }

        deinit {
            defaults.removePersistentDomain(forName: name)
        }
    }

    @Test
    func defaultsToGhosttysOwnSize() {
        #expect(TerminalFontPreference.current(in: ScratchDefaults().defaults) == 12)
    }

    @Test
    func savedSizeRoundTrips() {
        let scratch = ScratchDefaults()
        TerminalFontPreference.save(15.5, in: scratch.defaults)
        #expect(TerminalFontPreference.current(in: scratch.defaults) == 15.5)
    }

    @Test
    func resetReturnsToTheDefault() {
        let scratch = ScratchDefaults()
        TerminalFontPreference.save(20, in: scratch.defaults)
        TerminalFontPreference.reset(in: scratch.defaults)
        #expect(TerminalFontPreference.current(in: scratch.defaults) == TerminalFontPreference.defaultSize)
    }

    @Test
    func clampBoundsAndSnapsToHalfSteps() {
        #expect(TerminalFontPreference.clamp(3) == 8)
        #expect(TerminalFontPreference.clamp(99) == 24)
        // A raw pinch value never reaches the UI unsnapped, and the exact
        // half-step tie rounds away from zero.
        #expect(TerminalFontPreference.clamp(13.274) == 13.5)
        #expect(TerminalFontPreference.clamp(13.2) == 13.0)
        #expect(TerminalFontPreference.clamp(13.25) == 13.5)
    }

    @Test
    func labelDropsTheTrailingZeroOnWholeSizes() {
        #expect(TerminalFontPreference.label(for: 12) == "12")
        #expect(TerminalFontPreference.label(for: 13.5) == "13.5")
    }

    @Test
    func viewportRecordRoundTrips() {
        let scratch = ScratchDefaults()
        TerminalViewportRecord(width: 390, height: 610).save(in: scratch.defaults)
        #expect(TerminalViewportRecord.load(in: scratch.defaults) == TerminalViewportRecord(width: 390, height: 610))
        #expect(TerminalViewportRecord.load(in: ScratchDefaults().defaults) == nil)
    }

    @Test
    func viewportRecordClears() {
        let scratch = ScratchDefaults()
        TerminalViewportRecord(width: 390, height: 610).save(in: scratch.defaults)
        TerminalViewportRecord.clear(in: scratch.defaults)
        #expect(TerminalViewportRecord.load(in: scratch.defaults) == nil)
    }

    @Test
    func aZeroSizedViewportIsNeverSaved() {
        let scratch = ScratchDefaults()
        TerminalViewportRecord(width: 0, height: 610).save(in: scratch.defaults)
        #expect(TerminalViewportRecord.load(in: scratch.defaults) == nil)
    }
}
