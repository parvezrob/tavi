import SwiftUI

// Scan-first pairing (#45; PRD §7.2, mockup docs/assets/agent-deck-v1-
// pairing-flow.png). The person sees the host name and fingerprint at the
// moment of consent and is told plainly what the phone will be able to do;
// nothing is stored until the exchange and every check have passed.
struct PairingFlowView: View {
    let onPaired: (_ endpoint: HostEndpoint, _ grant: HostPairing.Grant) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .scan
    @State private var manualCode = ""
    @State private var showingManualEntry = false
    @State private var scanError: String?

    private enum Step: Equatable {
        case scan
        case verify(PairingPayload)
        case pairing(PairingPayload)
        case done(HostPairing.Grant, HostPairing.Checks)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            content
                .background(MochaTheme.canvas.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(isDone ? "Done" : "Cancel") { dismiss() }
                            .accessibilityIdentifier("pairing.close")
                    }
                }
        }
    }

    private var isDone: Bool {
        if case .done = step { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .scan: scanStep
        case let .verify(payload): verifyStep(payload)
        case .pairing: pairingStep
        case let .done(grant, checks): doneStep(grant, checks)
        case let .failed(message): failedStep(message)
        }
    }

    // MARK: - Scan

    private var scanStep: some View {
        VStack(spacing: 16) {
            if showingManualEntry || !PairingScannerView.isAvailable {
                manualEntry
            } else {
                PairingScannerView { text in handleCode(text) }
                    .clipShape(RoundedRectangle(cornerRadius: MochaTheme.cardRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: MochaTheme.cardRadius, style: .continuous)
                            .strokeBorder(MochaTheme.hairline, lineWidth: 1)
                    )
                    .frame(maxHeight: 360)
                    .accessibilityIdentifier("pairing.scanner")
                    .accessibilityLabel("Camera viewfinder for the pairing code")
            }

            if let scanError {
                Text(scanError)
                    .font(.footnote)
                    .foregroundStyle(MochaTheme.statusBlocked)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("pairing.scanError")
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "laptopcomputer")
                    .foregroundStyle(MochaTheme.textSecondary)
                Text("On your Mac, run **mocha pair** in the host folder (`npm run pair`) and point the camera at the code.")
                    .font(.footnote)
                    .foregroundStyle(MochaTheme.textSecondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .mochaCard()

            if PairingScannerView.isAvailable {
                Button(showingManualEntry ? "Scan instead" : "Enter code manually") {
                    showingManualEntry.toggle()
                    scanError = nil
                }
                .font(.footnote)
                .accessibilityIdentifier("pairing.toggleManual")
            }

            Spacer(minLength: 0)
            Label("No provider login. No public relay.", systemImage: "lock")
                .font(.caption2)
                .foregroundStyle(MochaTheme.textSecondary)
        }
        .padding(20)
        .navigationTitle("Scan pairing code")
    }

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste the code printed under the QR on your Mac.")
                .font(.footnote)
                .foregroundStyle(MochaTheme.textSecondary)
            TextField("mocha://pair?…", text: $manualCode, axis: .vertical)
                .lineLimit(2...5)
                .font(.footnote.monospaced())
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(12)
                .background(MochaTheme.well, in: RoundedRectangle(cornerRadius: MochaTheme.wellRadius, style: .continuous))
                .accessibilityIdentifier("pairing.manualCode")
            Button("Continue") { handleCode(manualCode) }
                .buttonStyle(.mochaProminent)
                .disabled(manualCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("pairing.manualContinue")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mochaCard()
    }

    private func handleCode(_ text: String) {
        do {
            step = .verify(try PairingPayload.decode(text))
            scanError = nil
        } catch {
            scanError = error.localizedDescription
        }
    }

    // MARK: - Verify

    private func verifyStep(_ payload: PairingPayload) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "desktopcomputer")
                .font(.largeTitle)
                .foregroundStyle(MochaTheme.textPrimary)
                .padding(.top, 8)
            Text(payload.hostName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(MochaTheme.textPrimary)
                .accessibilityIdentifier("pairing.hostName")
            Text(payload.endpoint.baseURL.host ?? "")
                .font(.caption.monospaced())
                .foregroundStyle(MochaTheme.textSecondary)

            VStack(spacing: 6) {
                Text(payload.fingerprint)
                    .font(.title3.monospaced().weight(.medium))
                    .foregroundStyle(MochaTheme.textPrimary)
                    .accessibilityIdentifier("pairing.fingerprint")
                Text("Confirm this fingerprint matches the one printed on \(payload.hostName).")
                    .font(.footnote)
                    .foregroundStyle(MochaTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .mochaCard()

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "shield")
                    .foregroundStyle(MochaTheme.statusBlocked)
                Text("This phone will be able to run commands on that Mac as your logged-in user. Pair only a Mac you own.")
                    .font(.footnote)
                    .foregroundStyle(MochaTheme.textPrimary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .mochaCard(stripe: MochaTheme.statusBlocked)

            Spacer(minLength: 0)

            Button {
                step = .pairing(payload)
                Task { await pair(payload) }
            } label: {
                Label("Pair securely", systemImage: "lock.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.mochaProminent)
            .accessibilityIdentifier("pairing.confirm")

            Button("Not this Mac") { step = .scan }
                .font(.footnote)
                .foregroundStyle(MochaTheme.textSecondary)
                .accessibilityIdentifier("pairing.reject")
        }
        .padding(20)
        .navigationTitle("Verify this Mac")
    }

    // MARK: - Pairing

    private var pairingStep: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Pairing…")
                .font(.callout)
                .foregroundStyle(MochaTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("pairing.inProgress")
    }

    private func pair(_ payload: PairingPayload) async {
        do {
            let grant = try await HostPairing.redeem(payload)
            let checks = try await HostPairing.verify(endpoint: payload.endpoint, credential: grant.credential)
            // Only now does anything persist: the credential proved itself
            // against the host that matched the code.
            onPaired(payload.endpoint, grant)
            step = .done(grant, checks)
        } catch {
            step = .failed(error.localizedDescription)
        }
    }

    // MARK: - Done / failed

    private func doneStep(_ grant: HostPairing.Grant, _ checks: HostPairing.Checks) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(MochaTheme.statusDone)
                .padding(.top, 8)
            Text("\(grant.hostName) is ready")
                .font(.title2.weight(.semibold))
                .foregroundStyle(MochaTheme.textPrimary)
                .accessibilityIdentifier("pairing.done")

            VStack(spacing: 0) {
                checkRow("TLS verified", "Tailscale Serve certificate")
                Divider().overlay(MochaTheme.hairline)
                checkRow("Direct path", "\(checks.latencyMilliseconds) ms round trip")
                Divider().overlay(MochaTheme.hairline)
                checkRow(
                    checks.herdrAvailable ? "\(checks.sessionsFound) session\(checks.sessionsFound == 1 ? "" : "s") found" : "Host reachable",
                    checks.herdrAvailable ? "Herdr is running" : "Herdr is not running yet; the terminal still works"
                )
                Divider().overlay(MochaTheme.hairline)
                checkRow("Credential saved in Keychain", "This iPhone only, as \(grant.deviceName)")
            }
            .mochaCard()

            Text("Closing Mocha never stops your agents. You can revoke this iPhone on \(grant.hostName) at any time with `mocha devices revoke`.")
                .font(.footnote)
                .foregroundStyle(MochaTheme.textSecondary)
                .multilineTextAlignment(.center)

            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Text("View sessions")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.mochaProminent)
            .accessibilityIdentifier("pairing.viewSessions")
        }
        .padding(20)
        .navigationTitle("Paired")
    }

    private func checkRow(_ title: String, _ detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(MochaTheme.statusDone)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(MochaTheme.textPrimary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(MochaTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .accessibilityElement(children: .combine)
    }

    private func failedStep(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(MochaTheme.statusBlocked)
                .padding(.top, 8)
            Text("Pairing didn't complete")
                .font(.title3.weight(.semibold))
                .foregroundStyle(MochaTheme.textPrimary)
            Text(message)
                .font(.footnote)
                .foregroundStyle(MochaTheme.textSecondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("pairing.failed")
            Text("Nothing was saved on this phone.")
                .font(.caption2)
                .foregroundStyle(MochaTheme.textSecondary)
            Spacer(minLength: 0)
            Button("Try again") {
                manualCode = ""
                scanError = nil
                step = .scan
            }
            .buttonStyle(.mochaProminent)
            .accessibilityIdentifier("pairing.retry")
        }
        .padding(20)
        .navigationTitle("Pairing")
    }
}
