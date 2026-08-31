# Mocha

Mocha is a fast, phone-first remote control surface for coding agents already running on your computers. It does not wrap Claude Code, Codex, or other tools in a new agent framework. It gives you a durable terminal session and a much better mobile interface for launching, watching, and steering them.

## Product planning

The maintained PRD, research, feature landscape, implementation plan, and visual review report live in [`docs/`](./docs/README.md). The product is a native SwiftUI app with a minimum deployment target of iOS 26 and an iPhone-first V1. iPad optimization and Android follow after the iPhone product and protocol are proven.

All implementation work is governed by the non-negotiable [`Mocha development principles`](./docs/DEVELOPMENT_PRINCIPLES.md). The SwiftUI app is the only client product; Mocha does not ship or maintain a browser client. The platform-neutral host contract lives in [`protocol/`](./protocol/README.md).

## How it works

```text
Native iPhone app
        │
        │ private HTTPS + WebSocket
        ▼
   Tailscale Serve
        │ localhost only
        ▼
 Mocha host ── node-pty ── herdr ── codex / claude / shell / anything
```

[herdr](https://herdr.dev) owns process lifetime, so an agent keeps running when the phone locks, changes networks, or disconnects. The host only translates terminal input/output to a small WebSocket protocol. There is no cloud relay and no agent-specific orchestration layer.

## Quick start on macOS

Requirements: Node.js 20+, [herdr](https://herdr.dev) (the terminal workspace the agents run in), and Tailscale on both the computer and phone.

```bash
npm install
npm run build
npm run service:install
tailscale serve --bg 8787
npm run token
```

`tailscale serve` prints a private HTTPS address such as `https://studio-mac.example.ts.net`. Then pair the phone: `npm run pair` prints a QR code; in Mocha, tap **Scan pairing code**, confirm the fingerprint matches, and you are in. `npm run devices` lists paired phones and `npm run devices revoke <id>` removes one. (`npm run token` reveals the host's own token, which the CLI uses; phones no longer need it.) This install path is developer-grade for now — see #47 for the one-command tester install.

The automatic background service is currently macOS-only. To run it in the foreground on any supported OS:

```bash
npm start
```

To remove the macOS background service:

```bash
npm run service:uninstall
```

## Development

```bash
npm install
npm run dev
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
| `MOCHA_HOST` | `127.0.0.1` | Bind address. Keep localhost when using Tailscale Serve. |
| `MOCHA_PORT` | `8787` | Local host port. |
| `MOCHA_TOKEN` | generated | Pairing token. Existing prototype credentials migrate atomically to `~/.mocha/config.json`. |
| `MOCHA_ROOTS` | common folders in home | Comma-separated roots shown in the project launcher. |
| `MOCHA_SHELL` | login shell | Shell used to identify shell sessions. |
| `MOCHA_MACHINE_NAME` | hostname | Display name sent to the phone. |

If you change configuration after installing the macOS service, run `npm run service:install` again so the LaunchAgent receives the new values.

## Security model

- The host binds to localhost by default. Tailscale Serve terminates HTTPS and makes it reachable only inside your tailnet.
- Every API and terminal connection also requires a random per-computer pairing token.
- Tokens are stored locally on the phone and computer. Mocha has no account, telemetry, or hosted backend.
- Treat the token as shell access. Anyone who has it and can reach the service can execute commands as your user.
- Do not use Tailscale Funnel or expose port `8787` directly to the public internet.

Tailscale documents that Serve proxies a localhost service over tailnet-only HTTPS and applies tailnet access rules: [Tailscale Serve documentation](https://tailscale.com/docs/features/tailscale-serve). The host terminal layer uses [node-pty](https://github.com/microsoft/node-pty) over `herdr agent attach`; the native client standardizes on a pinned GhosttyKit/Metal renderer.

## Current boundary

Mocha can attach to any herdr pane and can launch any CLI herdr knows. It cannot take over an arbitrary process that was started in a normal terminal or inside a vendor's GUI app; that process must already be running in herdr, or be resumed from a new CLI session using the vendor's own resume command.

That boundary is intentional. The universal primitive is the terminal, which preserves vendor independence and avoids maintaining a brittle adapter for every agent.
