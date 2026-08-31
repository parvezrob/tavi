import LocalAuthentication
import SwiftUI
import UIKit

// Face ID lock (#51, PRD §7.6): an optional gate over the whole app,
// default off until the owner decides otherwise. It protects the app on
// this phone, not the Mac — Settings says so in plain words.
//
// The cover is its own UIWindow above everything, not a view in the
// hierarchy: a ZStack sibling sits *under* any presented sheet (pairing,
// permission decisions, Settings itself) and never blocks VoiceOver from
// walking the content behind it. A window at alert level covers both. The
// cover goes up on scene-inactive so the app-switcher snapshot shows the
// lock screen, never the terminal.
struct AppLockGate<Content: View>: View {
    @AppStorage(AppLock.storageKey) private var faceIDLock = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var lock = AppLock()

    @ViewBuilder let content: Content

    var body: some View {
        content
            // Belt and braces: the lock window is key and modal, but the
            // content behind it must also vanish from the accessibility
            // tree while locked.
            .accessibilityHidden(lock.isLocked)
            .onAppear {
                if faceIDLock { lock.engage(authenticateNow: true) }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .inactive, .background:
                    if faceIDLock { lock.engage(authenticateNow: false) }
                case .active:
                    lock.authenticateIfLocked()
                @unknown default:
                    break
                }
            }
    }
}

@MainActor
@Observable
final class AppLock {
    // One storage key, shared with Settings' toggle and the DEBUG reset.
    static let storageKey = "mocha.security.faceIDLock"

    private(set) var isLocked = false
    private(set) var authenticating = false
    private(set) var failureMessage: String?
    // Whether device-owner authentication can run at all right now. When it
    // cannot (no passcode set, biometry removed), the lock screen offers a
    // way out — a lock nobody can pass is a bricked app, not security.
    private(set) var canAuthenticate = true

    private var window: UIWindow?

    func engage(authenticateNow: Bool) {
        isLocked = true
        canAuthenticate = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        showWindow()
        if authenticateNow { authenticate() }
    }

    func authenticateIfLocked() {
        guard isLocked else { return }
        authenticate()
    }

    func authenticate() {
        guard isLocked, !authenticating else { return }
        authenticating = true
        failureMessage = nil
        // Device-owner authentication: Face ID with the passcode as the
        // system's own fallback, so a failed scan can never lock the owner
        // out of their own phone's app.
        let context = LAContext()
        Task { @MainActor in
            defer { authenticating = false }
            do {
                let unlocked = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "Unlock Mocha"
                )
                if unlocked { release() }
            } catch {
                // Stays locked; the button retries. The message keeps the
                // system's own words rather than inventing a reason.
                failureMessage = error.localizedDescription
                canAuthenticate = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
            }
        }
    }

    // The escape hatch, offered only while authentication is impossible:
    // turning the lock off then is honest (it could not protect anything)
    // and never a bypass when Face ID or the passcode still works.
    func disableLock() {
        guard !canAuthenticate else { return }
        UserDefaults.standard.set(false, forKey: Self.storageKey)
        release()
    }

    private func release() {
        isLocked = false
        failureMessage = nil
        window?.isHidden = true
        window = nil
    }

    private func showWindow() {
        if window != nil { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState != .unattached }) ?? scenes.first else {
            return
        }
        let cover = UIWindow(windowScene: scene)
        cover.windowLevel = .alert + 1
        let controller = UIHostingController(rootView: AppLockScreen(lock: self))
        controller.view.backgroundColor = .clear
        cover.rootViewController = controller
        cover.makeKeyAndVisible()
        window = cover
    }
}

private struct AppLockScreen: View {
    let lock: AppLock

    var body: some View {
        ZStack {
            MochaTheme.canvas.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(MochaTheme.textSecondary)
                Text("Mocha is locked")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(MochaTheme.textPrimary)
                if let message = lock.failureMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(MochaTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Button {
                    lock.authenticate()
                } label: {
                    Label("Unlock", systemImage: "faceid")
                }
                .buttonStyle(.mochaProminent)
                .disabled(lock.authenticating)
                .accessibilityIdentifier("lock.unlock")
                if !lock.canAuthenticate {
                    Text("Face ID and the passcode are unavailable on this iPhone, so the lock cannot be checked.")
                        .font(.footnote)
                        .foregroundStyle(MochaTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button("Turn off the lock") {
                        lock.disableLock()
                    }
                    .font(.footnote)
                    .accessibilityIdentifier("lock.turnOff")
                }
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("lock.screen")
    }
}
