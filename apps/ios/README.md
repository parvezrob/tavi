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
