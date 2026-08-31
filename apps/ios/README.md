# Mocha for iOS

This directory owns the native SwiftUI client, its Xcode project, local Swift packages, and iOS tests.

Locked project identity: product/target/module `Mocha`, bundle identifier `com.parvezrob.mocha`, minimum deployment target iOS 26, and iPhone-first V1. iPad optimization is a later planned phase and does not block the first iPhone release.

The application consumes the versioned contract in [`../../protocol/`](../../protocol/README.md). SwiftUI owns navigation and native surfaces; the terminal renderer remains behind a small UIKit/GhosttyKit adapter so transport, rendering, and provider semantics stay independent.

The Xcode-generated project and shared `Mocha` scheme live in this directory. Never commit personal signing data, `xcuserdata`, Derived Data, or credentials.

Build the pinned custom-I/O GhosttyKit dependency before working on the terminal surface:

```bash
./scripts/build-ghosttykit.sh
```

The script downloads checksum-verified Zig 0.15.2, checks out Ghostty commit `91fe505e60bbe72ff08c881d2882acad6a56cb9f`, applies Mocha's reviewed downstream patches, and creates a local ignored `Frameworks/GhosttyKit.xcframework` symlink. The binary is intentionally not committed. Xcode 26 requires its separately distributed Metal Toolchain; if it is missing, install it with `xcodebuild -downloadComponent MetalToolchain`.

Every terminal is a herdr agent pane reached through the host's agent route. Debug builds accept `MOCHA_DEV_HOST` and `MOCHA_DEV_TOKEN` as transient launch-environment values for automated simulator qualification, and `MOCHA_DEV_AGENT=<paneId>` opens that pane's terminal straight from launch. Never add the token to a shared scheme, source file, test fixture, command log, or committed configuration.

The terminal connection requires a Tailscale Serve `.ts.net` HTTPS/WSS origin, rejects credentials embedded in URLs, sends the token through the standard `Authorization` header, retains it only in process memory for reconnect, and never automatically replays input whose delivery is uncertain. Mocha cannot determine from the hostname whether Funnel is enabled, so keep Funnel disabled. Closing the mobile attachment does not kill the herdr-owned pane.

Build and test the baseline on the current iPhone simulator runtime:

```bash
xcodebuild build \
  -project apps/ios/Mocha.xcodeproj \
  -scheme Mocha \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  CODE_SIGNING_ALLOWED=NO

xcodebuild test \
  -project apps/ios/Mocha.xcodeproj \
  -scheme Mocha \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  CODE_SIGNING_ALLOWED=NO
```
