# Mocha for iOS

This directory owns the native SwiftUI client, its Xcode project, local Swift packages, and iOS tests.

The application consumes the versioned contract in [`../../protocol/`](../../protocol/README.md). SwiftUI owns navigation and native surfaces; the terminal renderer remains behind a small UIKit/GhosttyKit adapter so transport, rendering, and provider semantics stay independent.

Create project files through Xcode and commit the generated shared scheme. Never commit personal signing data, `xcuserdata`, Derived Data, or credentials.
