import Foundation

struct TerminalAccessibleTranscript {
    private enum ParserState {
        case controlSequence
        case escape
        case normal
        case operatingSystemCommand
        case operatingSystemCommandEscape
    }

    private let maximumScalars: Int
    private var parserState: ParserState = .normal
    private(set) var value = ""

    init(maximumScalars: Int = 8_192) {
        precondition(maximumScalars > 0)
        self.maximumScalars = maximumScalars
    }

    mutating func append(_ data: Data) {
        for scalar in String(decoding: data, as: UTF8.self).unicodeScalars {
            consume(scalar)
        }
        if value.unicodeScalars.count > maximumScalars {
            value = String(value.unicodeScalars.suffix(maximumScalars))
        }
    }

    private mutating func consume(_ scalar: Unicode.Scalar) {
        switch parserState {
        case .normal:
            consumePrintable(scalar)
        case .escape:
            switch scalar.value {
            case 0x5B:
                parserState = .controlSequence
            case 0x5D:
                parserState = .operatingSystemCommand
            default:
                parserState = .normal
            }
        case .controlSequence:
            if (0x40...0x7E).contains(scalar.value) {
                parserState = .normal
            }
        case .operatingSystemCommand:
            if scalar.value == 0x07 {
                parserState = .normal
            } else if scalar.value == 0x1B {
                parserState = .operatingSystemCommandEscape
            }
        case .operatingSystemCommandEscape:
            parserState = scalar.value == 0x5C ? .normal : .operatingSystemCommand
        }
    }

    private mutating func consumePrintable(_ scalar: Unicode.Scalar) {
        switch scalar.value {
        case 0x1B:
            parserState = .escape
        case 0x08:
            if !value.isEmpty { value.removeLast() }
        case 0x09:
            value.append("\t")
        case 0x0A:
            value.append("\n")
        case 0x0D:
            break
        case 0x00...0x1F, 0x7F:
            break
        default:
            value.unicodeScalars.append(scalar)
        }
    }
}
