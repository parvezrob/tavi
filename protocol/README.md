# Mocha host protocol

**Status:** current prototype contract
**Protocol:** `mocha.v1`
**Updated:** 2026-08-31

This document preserves the transport contract used by the native Mocha client. It is platform-neutral and is the compatibility baseline while the protocol evolves toward versioned capability negotiation.

## Transport and trust boundary

- The host listens on `127.0.0.1:8787` by default.
- Tailscale Serve provides tailnet-only HTTPS and WebSocket access.
- Do not expose the host directly to the public internet or through Tailscale Funnel.
- Every protected HTTP request and terminal connection requires the per-host token.
- Treat the token as shell access. The current token is a bootstrap-era credential, not the final per-device pairing design.
- JSON response bodies use UTF-8. Successful responses and errors are not cacheable.

### Prototype namespace migration

- Active runtime identifiers use `mocha`: `MOCHA_*`, `~/.mocha`, `mocha-*`, and `mocha.v1`.
- On first start, a valid legacy `~/.agent-deck/config.json` token is copied atomically into `~/.mocha/config.json`; the legacy file remains as a rollback source.
- Conflicting current and legacy credentials stop startup with an actionable error. The host never guesses which shell-access credential is authoritative.
- Legacy `DECK_*` environment variables are rejected. Reinstall the service or rename the variables explicitly.
- Existing `deck-*` tmux sessions remain discoverable and attachable, while every new managed session uses the `mocha-*` prefix.

## HTTP authentication

Send the token on every `/api/*` request except health:

```http
Authorization: Bearer <token>
```

An absent or invalid token returns:

```json
{ "error": "Invalid access token." }
```

with status `401`.

## HTTP endpoints

### `GET /api/health`

Unauthenticated liveness and version check.

```json
{ "ok": true, "version": "0.1.0" }
```

### `GET /api/host`

```json
{
  "name": "Studio Mac",
  "platform": "darwin",
  "arch": "arm64",
  "version": "0.1.0",
  "tmuxVersion": "tmux 3.5a"
}
```

### `GET /api/sessions`

Returns `{ "sessions": SessionInfo[] }`, ordered by most recent activity.

```json
{
  "sessions": [
    {
      "id": "mocha-api-work-a1b2c3",
      "name": "api work",
      "createdAt": 1787086800000,
      "activeAt": 1787086860000,
      "attached": 1,
      "windows": 2,
      "cwd": "/Users/example/Projects/api",
      "command": "codex",
      "managed": true,
      "agent": "codex"
    }
  ]
}
```

`agent` is one of `shell`, `codex`, `claude`, or `custom`. It is inferred from the tmux pane command and is descriptive, not proof of semantic agent state.

### `POST /api/sessions`

Request:

```json
{
  "name": "API work",
  "cwd": "/Users/example/Projects/api",
  "agent": "codex"
}
```

`name` is 1–80 characters, `cwd` must be an accessible absolute directory, and `agent` must be a supported value. A `custom` agent requires a non-empty `command`; other agents may also supply a command override. Commands are limited to 4,096 characters.

Returns `{ "session": SessionInfo }` with status `201`.

### `DELETE /api/sessions/{id}`

Stops the tmux session. Returns `204` on success or `404` when it no longer exists. Session IDs are limited to 1–128 characters from `A-Z`, `a-z`, `0-9`, `_`, `.`, `:`, and `-`.

### `GET /api/workspaces`

```json
{
  "workspaces": [
    { "name": "api", "path": "/Users/example/Projects/api", "git": true }
  ]
}
```

The host returns configured roots and their immediate visible child directories, with Git roots first.

### `GET /api/projects`

Everything a client needs to choose where a new agent starts.

```json
{
  "recent": [
    {
      "path": "/Users/example/Projects/api",
      "name": "api",
      "lastUsedAt": "2026-08-31T09:12:04.000Z",
      "active": true,
      "withinRoots": true
    }
  ],
  "workspaces": [
    { "name": "api", "path": "/Users/example/Projects/api", "git": true }
  ],
  "roots": ["/Users/example/Projects"],
  "agents": [
    { "kind": "claude", "label": "Claude Code", "installed": true },
    { "kind": "gemini", "label": "Gemini CLI", "installed": false }
  ]
}
```

`agents` is every agent kind the host's herdr can launch, in the host's preferred order, with a display label and whether the executable resolves on the Mac's login-shell PATH. Clients offer only installed kinds for creation; the rest are listed so a missing agent is explainable rather than absent.

`recent` merges the folders agents are running in right now (`active: true`) with the folders this host has previously launched an agent in. Folders with a live agent come first, then the most recently chosen; `lastUsedAt` is absent for a folder known only from a live agent, and a remembered folder that no longer exists on disk is omitted rather than offered. `name` is the folder's basename. `withinRoots` says whether the folder sits inside `roots`, so a client can mark the folders whose creation will require the confirmation described below instead of discovering it after a failed request. `workspaces` is the same scan as `GET /api/workspaces`.

`roots` may be empty — a host with none of the default project directories and no `MOCHA_ROOTS` configures no roots at all, and then *every* create requires the confirmation below. Path comparison is case- and Unicode-normalization-insensitive, matching the default macOS filesystem.

### `POST /api/herdr/tabs`

Creates a Herdr tab and launches an agent in it.

```json
{ "agent": "claude", "cwd": "/Users/example/Projects/api", "allowOutsideRoots": false }
```

`agent` is any `kind` from `GET /api/projects` → `agents` (herdr's supported set — `claude`, `codex`, `gemini`, `opencode`, `copilot`, `cursor`, … — plus `shell`), or absent for a bare tab that nothing will list. `shell` launches nothing: the host reports the pane's own shell to herdr as an agent named `shell` (via `pane.report_agent`) so it lists in `/api/agents`, opens through the agent terminal, and carries status `idle` — herdr keeps a reported state rather than overriding it from screen detection. A kind that is not installed on the Mac is refused with `400` (`"<Label> is not installed on this Mac."`) — herdr would otherwise return a tab whose launch has already failed. `cwd` is **required** and must be an absolute path to an existing directory — the host never starts an agent in an unspecified location. A `cwd` outside the configured roots is refused with `400` and `{ "outsideRoots": true }` unless the request carries `allowOutsideRoots: true`, which clients send only after confirming the custom location with the person.

| Status | Meaning |
| --- | --- |
| `201` | Created; body is `{ "paneId", "tabId" }`. The folder is recorded in the recent list above. |
| `400` | Unknown `agent`, missing or unusable `cwd`, or an unconfirmed location outside the roots (`outsideRoots: true`). |
| `404` | Herdr is not configured on this host. |
| `503` | Herdr is configured but could not create the tab. |

**Compatibility.** Requiring `cwd` is a breaking change to this endpoint, made while Mocha is pre-MVP with a single first-party client shipped alongside the host. A client that omits `cwd` gets `400` on every create and must be updated with the host; there is no negotiated fallback. Deploy the host and the app together.

## Terminal WebSocket

Connect to:

```text
wss://<tailnet-host>/api/sessions/{id}/terminal
```

Send the access token in the standard authorization header:

```http
Authorization: Bearer <token>
```

Offer only the `mocha.v1` WebSocket subprotocol. The server must select that exact protocol; a missing or unsupported protocol returns HTTP `400` before session lookup or PTY creation. Authentication failure returns `401`, and an unknown session returns `404` before upgrade.

Every application frame is a UTF-8 JSON text frame no larger than 64 KiB. Binary frames return an error and close with code `1003`; oversized client frames return an error and close with code `1009`. The host chunks large PTY output into bounded frames and pauses the temporary PTY attachment when the WebSocket send buffer crosses its high-water mark. On connection the host creates the attachment using `TERM=xterm-256color` and true color.

### Client messages

Terminal input:

```json
{ "type": "input", "data": "npm test\r" }
```

Terminal resize:

```json
{ "type": "resize", "cols": 100, "rows": 30 }
```

The host clamps columns to `20...400` and rows to `5...200`.

Connection liveness probe:

```json
{ "type": "ping", "id": "5A13F176-0F83-4DF9-94BB-A63A678A1F2A" }
```

`id` is an opaque 1–64 character ASCII identifier using letters, digits, and hyphens. The host echoes it in a `pong`; it does not interpret or persist the value.

### Server messages

```json
{ "type": "ready" }
```

```json
{ "type": "output", "data": "\u001b[32mready\u001b[0m\r\n" }
```

```json
{ "type": "pong", "id": "5A13F176-0F83-4DF9-94BB-A63A678A1F2A" }
```

```json
{ "type": "exit", "code": 0, "signal": 15 }
```

```json
{ "type": "error", "message": "Invalid terminal message." }
```

`signal` is optional. Unknown or malformed messages return an `error` without writing to the PTY. A normal PTY exit closes the socket with code `1000`. Failure to open the terminal closes with code `1011`. Closing the socket kills only the temporary attachment PTY; tmux continues to own the durable session and its child process.

The shared compatibility fixtures live in [`fixtures/terminal-v1/`](./fixtures/terminal-v1/). They are synthetic and contain no captured prompts, terminal contents, credentials, or private paths.

## Terminal WebSocket v2 (`mocha.v2`)

Clients should offer the `mocha.v2` subprotocol; the server prefers it and falls back to `mocha.v1` when only that is offered. v2 changes output delivery and reconnect semantics; client messages (`input`, `resize`, `ping`) and the `pong`/`exit`/`error` server messages are unchanged and remain JSON text frames.

### Persistent attachment

The host keeps one PTY attachment per session that survives WebSocket drops. After the last client disconnects the attachment is retained for a bounded window (default 120 s) and its output accumulates in a ring buffer (default 1 MiB) tagged with absolute byte offsets. Each attachment has a random `stream` epoch token; offsets are meaningful only within one epoch. Only one client owns an attachment at a time — a new connection to the same session supersedes the previous one, which receives an `error` and close code `1000` (`superseded`).

### Ready and resume

The v2 `ready` message carries the stream epoch and the client's starting offset:

```json
{ "type": "ready", "stream": "0d5f…", "offset": 0, "resumed": false }
```

To resume after a drop, reconnect with query parameters:

```text
wss://<host>/api/sessions/{id}/terminal?stream=<epoch>&resume=<offset>
```

where `offset` is the absolute offset one past the last byte the client has rendered. On a hit (`resumed: true`) the host replays exactly the missed bytes — no gap, no duplication. On any miss (attachment gone or exited, epoch mismatch, offset trimmed out of the ring) the host discards the old attachment, spawns a fresh attach (tmux repaints the full screen), and answers `resumed: false` with a new `stream` and `offset` — the client must reset its offset counter to `offset`.

### Binary output frames

Output travels as binary WebSocket frames:

```text
[0x01][8-byte big-endian start offset][raw PTY bytes]
```

The client's next resume offset is `start offset + payload length`. Frames are bounded by the 64 KiB frame limit. A client that falls further behind than the ring buffer receives an `error` and close code `1011` (`resume buffer overrun`); it should reconnect without resume parameters for a fresh attach.

## Client invariants

- Send the current dimensions immediately after WebSocket open and whenever the rendered grid changes.
- Render `output.data` as terminal bytes represented in a JavaScript/Swift UTF-8 string; do not parse agent prose from it.
- Never replay unacknowledged input after reconnect. Ambiguous duplication is worse than requiring the user to resend.
- Treat disconnect as normal. Reconnect with bounded exponential backoff and surface the connection state.
- Keep rendering, transport, session durability, and optional provider semantics as separate components.

## Planned evolution

The next protocol version adds a handshake, stable machine identity, per-device credentials, capability negotiation, provider/target identifiers, resumable event cursors, bounded frames, and a typed error taxonomy. Until then, changes to the contract above require corresponding host tests and native-client compatibility fixtures.
