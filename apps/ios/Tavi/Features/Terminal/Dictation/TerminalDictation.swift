import SwiftUI

extension TerminalSessionView {
    // One button, three honest looks: plain mic, a spinner while permission
    // or the model download is pending, and a filled red mic while listening.
    // The transcript is never sent by this button or by anything else here —
    // Send stays a separate, deliberate tap.
    var dictationButton: some View {
        Button {
            switch dictation.state {
            case .idle, .failed:
                dictation.dismissFailure()
                composerError = nil
                dictation.start(draft: composerText) { composerText = $0 }
            case .preparing, .listening:
                dictation.stop()
            }
        } label: {
            switch dictation.state {
            case .preparing:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 28, height: 28)
            case .listening:
                Image(systemName: "mic.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, options: .repeating)
            case .idle, .failed:
                Image(systemName: "mic")
                    .font(.title2)
            }
        }
        .disabled(composerSending || !controller.connectionState.canSubmitInput)
        .accessibilityLabel(dictation.state.isActive ? "Stop dictating" : "Dictate")
        .accessibilityIdentifier("terminal.dictate")
    }

    var dictationCaption: (text: String, isFailure: Bool, offersSettings: Bool)? {
        switch dictation.state {
        case .idle:
            return nil
        case .preparing(.permission):
            return ("Waiting for microphone access…", false, false)
        case .preparing(.downloadingModel):
            return ("Downloading the on-device speech model — first time only.", false, false)
        case .listening:
            return ("Listening — tap the mic to stop, then edit and send.", false, false)
        case let .failed(failure):
            return (failure.message, true, failure.isPermissionDenied)
        }
    }
}

// Eight bars that breathe with the microphone: the only proof, while the
// keyboard is down, that the phone is actually hearing something.
struct DictationLevelMeter: View {
    let level: Float

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<8, id: \.self) { index in
                let threshold = Float(index) / 8
                Capsule()
                    .fill(level > threshold ? Color.red : TaviTheme.textSecondary.opacity(0.35))
                    .frame(width: 3, height: 4 + CGFloat(index) * 1.2)
            }
        }
        .frame(height: 14)
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}
