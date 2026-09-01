# Tavi

**Tavi** — *Terminal Agent Vantage and Intervention* — by Farfield. Tavi is a fast, phone-first remote control surface for coding agents already running on your computers. It does not wrap Claude Code, Codex, or other tools in a new agent framework. It gives you a durable terminal session and a much better mobile interface for launching, watching, and steering them.

## Product planning

The maintained PRD, research, feature landscape, implementation plan, and visual review report live in [`docs/`](./docs/README.md). The product is a native SwiftUI app with a minimum deployment target of iOS 26 and an iPhone-first V1. iPad optimization and Android follow after the iPhone product and protocol are proven.

All implementation work is governed by the non-negotiable [`Tavi development principles`](./docs/DEVELOPMENT_PRINCIPLES.md). The SwiftUI app is the only client product; Tavi does not ship or maintain a browser client. The platform-neutral host contract lives in [`protocol/`](./protocol/README.md).

## How it works

```text
Native iPhone app
        │
        │ private HTTPS + WebSocket
        ▼
   Tailscale Serve
        │ localhost only
        ▼
 Tavi host ── node-pty ── herdr ── codex / claude / shell / anything
```

[herdr](https://herdr.dev) owns process lifetime, so an agent keeps running when the phone locks, changes networks, or disconnects. The host only translates terminal input/output to a small WebSocket protocol. There is no cloud relay and no agent-specific orchestration layer.

## Quick start on macOS

You need Node.js 20+ on the computer (macOS or Linux), Tailscale signed in on the phone, and the Tavi app on the phone. Then, on the computer:

```bash
npx tavi-host pair
```

That one command shows a short checklist of what the computer already has and what it will set up — Tailscale (installed and signed in), a private address for your phone, Tavi running in the background, [herdr](https://herdr.dev) for the agent cards — asks once, does it, and prints a QR code. In Tavi on the phone, tap **Scan pairing code**, confirm the fingerprint matches what the terminal shows, and you are in. `npx tavi-host doctor` shows every check without changing anything; `npx tavi-host pair --yes` answers yes to everything for scripts.

herdr is optional but is what makes the agent cards work: without it Tavi is a plain remote terminal. Enable HTTPS certificates for your tailnet once (Tailscale admin → DNS → HTTPS Certificates) if `tailscale serve` refuses.

Afterwards Tavi keeps itself up to date: the background host checks npm once a day, installs a newer version beside the current one, and restarts — and if the new version fails to start it goes back to the previous one on its own. Nothing to re-run. `npx tavi-host update` checks right now; `npx tavi-host doctor` shows every check; `npx tavi-host devices` lists paired phones and `devices revoke <id>` cuts one off; `uninstall-service` removes the background host; `install-claude-hooks` lets Claude Code report permission waits to the phone. (`npx` runs from a temporary cache, so the first pair installs a permanent copy under `~/.tavi/runtime` and the service runs from there; a git checkout or `npm i -g tavi-host` runs in place and does not self-update.)

On Linux the host runs as a systemd user service (`~/.config/systemd/user/tavi-host.service`) and the command asks for your password once if Tailscale needs your user made an operator. No compiler is needed on Linux x64/arm64; if the terminal module ever fails to load, `npx tavi-host doctor` says exactly what to do.

## Development

```bash
npm install
npm run build && npm run service:install   # run this checkout as the login service
npm run pair                               # same bootstrap as npx, from the checkout
npm run dev                                # foreground host with reload, for iteration
```

The default command runs only the local host service. Native client development is performed from the Xcode project once the SwiftUI workspace is created.

Repository ownership stays intentionally narrow:

```text
apps/host/   local host service
apps/ios/    native Apple client and tests
protocol/    shared wire contract and compatibility fixtures
docs/        maintained product and architecture sources
scripts/     reproducible repository tooling
```

GitHub Issues are the work queue and sole known-issue tracker. During the owner-approved MVP fast track, one integration session may push verified issue-scoped commits directly to `main`; normal short-lived branch and pull-request flow begins after the MVP gate. The repository does not maintain a parallel bug ledger or session diary. Contributors and coding agents follow [`AGENTS.md`](./AGENTS.md).

Useful checks:

```bash
npm run check
npm test
npm run build
```

## Configuration

Copy [`.env.example`](./.env.example) or set environment variables before running the host.

| Variable | Default | Purpose |
| --- | --- | --- |
| `TAVI_HOST` | `127.0.0.1` | Bind address. Keep localhost when using Tailscale Serve. |
| `TAVI_PORT` | `8787` | Local host port. |
| `TAVI_TOKEN` | generated | Pairing token. Existing prototype credentials migrate atomically to `~/.tavi/config.json`. |
| `TAVI_ROOTS` | common folders in home | Comma-separated roots shown in the project launcher. |
| `TAVI_SHELL` | login shell | Shell used to identify shell sessions. |
| `TAVI_MACHINE_NAME` | hostname | Display name sent to the phone. |

If you change configuration after installing the macOS service, run `npm run service:install` again so the LaunchAgent receives the new values.

## Security model

- The host binds to localhost by default. Tailscale Serve terminates HTTPS and makes it reachable only inside your tailnet.
- Every API and terminal connection also requires a random per-computer pairing token.
- Tokens are stored locally on the phone and computer. Tavi has no account, telemetry, or hosted backend.
- Treat the token as shell access. Anyone who has it and can reach the service can execute commands as your user.
- Do not use Tailscale Funnel or expose port `8787` directly to the public internet.

Tailscale documents that Serve proxies a localhost service over tailnet-only HTTPS and applies tailnet access rules: [Tailscale Serve documentation](https://tailscale.com/docs/features/tailscale-serve). The host terminal layer uses [node-pty](https://github.com/microsoft/node-pty) over `herdr agent attach`; the native client standardizes on a pinned GhosttyKit/Metal renderer.

## Current boundary

Tavi can attach to any herdr pane and can launch any CLI herdr knows. It cannot take over an arbitrary process that was started in a normal terminal or inside a vendor's GUI app; that process must already be running in herdr, or be resumed from a new CLI session using the vendor's own resume command.

That boundary is intentional. The universal primitive is the terminal, which preserves vendor independence and avoids maintaining a brittle adapter for every agent.

## Licensing

The host package (`apps/host`, published to npm as [`tavi-host`](https://www.npmjs.com/package/tavi-host)) is licensed under the [Apache License 2.0](./apps/host/LICENSE) — it runs with shell access on your computer, so it should be readable and freely auditable. Everything else in this repository, including the Tavi iOS app, is © 2026 Farfield, all rights reserved. "Tavi" and "Farfield" are names of Farfield.
