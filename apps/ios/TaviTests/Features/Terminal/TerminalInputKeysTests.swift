import Foundation
import Testing
@testable import Tavi

struct TerminalControlKeyMapperTests {
    @Test
    func mapsLettersToControlCodes() {
        #expect(TerminalControlKeyMapper.controlCode(for: Data("c".utf8)) == Data([0x03]))
        #expect(TerminalControlKeyMapper.controlCode(for: Data("C".utf8)) == Data([0x03]))
        #expect(TerminalControlKeyMapper.controlCode(for: Data("a".utf8)) == Data([0x01]))
        #expect(TerminalControlKeyMapper.controlCode(for: Data("z".utf8)) == Data([0x1A]))
    }

    @Test
    func mapsPunctuationControlCounterparts() {
        #expect(TerminalControlKeyMapper.controlCode(for: Data("[".utf8)) == Data([0x1B]))
        #expect(TerminalControlKeyMapper.controlCode(for: Data("_".utf8)) == Data([0x1F]))
        #expect(TerminalControlKeyMapper.controlCode(for: Data("@".utf8)) == Data([0x00]))
    }

    @Test
    func passesUnmappableInputThrough() {
        #expect(TerminalControlKeyMapper.controlCode(for: Data("1".utf8)) == nil)
        #expect(TerminalControlKeyMapper.controlCode(for: Data(" ".utf8)) == nil)
        #expect(TerminalControlKeyMapper.controlCode(for: Data("ab".utf8)) == nil)
        #expect(TerminalControlKeyMapper.controlCode(for: Data()) == nil)
    }
}

struct TerminalQuickKeyTests {
    @Test
    func completedRowCoversPRDKeys() {
        #expect(TerminalQuickKey.shiftTab.sequence == "\u{1B}[Z")
        #expect(TerminalQuickKey.enter.sequence == "\r")
        #expect(TerminalQuickKey.escape.sequence == "\u{1B}")
        #expect(TerminalQuickKey.interrupt.sequence == "\u{03}")
    }
}
