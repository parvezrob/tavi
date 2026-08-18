# Mocha for iOS

This directory owns the native SwiftUI client, its Xcode project, local Swift packages, and iOS tests.

Locked project identity: product/target/module `Mocha`, bundle identifier `com.parvezrob.mocha`, minimum deployment target iOS 26, and iPhone-first V1. iPad optimization is a later planned phase and does not block the first iPhone release.

The application consumes the versioned contract in [`../../protocol/`](../../protocol/README.md). SwiftUI owns navigation and native surfaces; the terminal renderer remains behind a small UIKit/GhosttyKit adapter so transport, rendering, and provider semantics stay independent.

Create project files through Xcode and commit the generated shared scheme. Never commit personal signing data, `xcuserdata`, Derived Data, or credentials.
