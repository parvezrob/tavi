# Owner environment

> The owner's machines and identifiers, so any session (or any assistant) can run the live loops without re-discovery. **Contains machine identifiers — review before ever making this repository public.** Durable engineering knowledge does not belong here; it goes in the other docs.

- **Mac (primary host):** Tailscale Serve URL `https://parvezs-macbook-air.tail4c71f5.ts.net` → :8787. The host runs from this checkout as launchd `com.farfield.tavi.host` (`npm run build && npm run service:install` from `apps/host`; checkout hosts never self-update). herdr 0.8.2 under `brew services start herdr` (headless). Claude hooks installed.
- **ubuntu box:** shows on the phone as `robin-PC`; installed via `npx tavi-host pair` (managed runtime, self-updates).
- **iPhone 12 Pro:** UDID `9B6F918E-EED4-59EA-8BF3-0ED972C01B93`. Free-Apple-ID signing → the profile expires every **7 days**; rebuild with `-allowProvisioningUpdates` and reinstall (`xcrun devicectl device install app …`); the owner re-trusts in Settings if asked. Build for the device into a separate `-derivedDataPath` so simulator tests can run beside it.
- **Simulator:** "iPhone 17 Pro" `3CA94743-421A-4866-BD4F-2A92149AFE82`.
- **Live test credentials:** export `TEST_RUNNER_TAVI_DEV_HOST` (the Mac URL above) and `TEST_RUNNER_TAVI_DEV_TOKEN` (`npm run -s token` in `apps/host`).
- **npm publishing** is the owner's alone: 2FA in a real Terminal.app (the auth URL is masked under coding agents). Bump `apps/host/package.json` + `VERSION` only when declaring a release worth publishing; versions are immutable; propagation 1–2 min; every publish restarts every paired host.
