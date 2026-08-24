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
    private var scalars: [Unicode.Scalar?]
    private var firstScalarIndex = 0
    private var scalarCount = 0

    var isEmpty: Bool { scalarCount == 0 }

    var value: String {
        var result = String.UnicodeScalarView()
        result.reserveCapacity(scalarCount)
        for offset in 0..<scalarCount {
            let index = (firstScalarIndex + offset) % maximumScalars
            if let scalar = scalars[index] {
                result.append(scalar)
            }
        }
        return String(result)
    }

    init(maximumScalars: Int = 8_192) {
        precondition(maximumScalars > 0)
        self.maximumScalars = maximumScalars
        scalars = Array(repeating: nil, count: maximumScalars)
    }

    mutating func append(_ data: Data) {
        for scalar in String(decoding: data, as: UTF8.self).unicodeScalars {
            consume(scalar)
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
            removeLastScalar()
        case 0x09:
            appendScalar(scalar)
        case 0x0A:
            appendScalar(scalar)
        case 0x0D:
            break
        case 0x00...0x1F, 0x7F:
            break
        default:
            appendScalar(scalar)
        }
    }

    private mutating func appendScalar(_ scalar: Unicode.Scalar) {
        if scalarCount < maximumScalars {
            let index = (firstScalarIndex + scalarCount) % maximumScalars
            scalars[index] = scalar
            scalarCount += 1
            return
        }

        scalars[firstScalarIndex] = scalar
        firstScalarIndex = (firstScalarIndex + 1) % maximumScalars
    }

    private mutating func removeLastScalar() {
        guard scalarCount > 0 else { return }
        let index = (firstScalarIndex + scalarCount - 1) % maximumScalars
        scalars[index] = nil
        scalarCount -= 1
        if scalarCount == 0 {
            firstScalarIndex = 0
        }
    }
}
