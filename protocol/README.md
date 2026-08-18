# Mocha host protocol

**Status:** current prototype contract
**Protocol:** `mocha.v1`
**Updated:** 2026-08-19

This document preserves the transport contract used by the native Mocha client. It is platform-neutral and is the compatibility baseline while the protocol evolves toward versioned capability negotiation.

## Transport and trust boundary

- The host listens on `127.0.0.1:8787` by default.
- Tailscale Serve provides tailnet-only HTTPS and WebSocket access.
- Do not expose the host directly to the public internet or through Tailscale Funnel.
- Every protected HTTP request and terminal connection requires the per-host token.
- Treat the token as shell access. The current token is a bootstrap-era credential, not the final per-device pairing design.
- JSON response bodies use UTF-8. Successful responses and errors are not cacheable.

### Prototype namespace migration

- Active runtime identifiers use `mocha`: `MOCHA_*`, `~/.mocha`, `mocha-*`, `mocha.v1`, and `mocha.token.*`.
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

## Terminal WebSocket

Connect to:

```text
wss://<tailnet-host>/api/sessions/{id}/terminal
```

Offer both WebSocket subprotocols:

```text
mocha.v1
mocha.token.<base64url-encoded UTF-8 token>
```

The server selects `mocha.v1`. Authentication failure returns HTTP `401`; an unknown session returns `404` before upgrade.

All frames are UTF-8 JSON. A client frame larger than 64 KiB is ignored. On connection the host creates a PTY attached to the existing tmux session using `TERM=xterm-256color` and true color.

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

### Server messages

```json
{ "type": "ready" }
```

```json
{ "type": "output", "data": "\u001b[32mready\u001b[0m\r\n" }
```

```json
{ "type": "exit", "code": 0, "signal": 15 }
```

```json
{ "type": "error", "message": "Invalid terminal message." }
```

`signal` is optional. A normal PTY exit closes the socket with code `1000`. Failure to open the terminal closes with code `1011`. Closing the socket kills only the temporary attachment PTY; tmux continues to own the durable session and its child process.

## Client invariants

- Send the current dimensions immediately after WebSocket open and whenever the rendered grid changes.
- Render `output.data` as terminal bytes represented in a JavaScript/Swift UTF-8 string; do not parse agent prose from it.
- Never replay unacknowledged input after reconnect. Ambiguous duplication is worse than requiring the user to resend.
- Treat disconnect as normal. Reconnect with bounded exponential backoff and surface the connection state.
- Keep rendering, transport, session durability, and optional provider semantics as separate components.

## Planned evolution

The next protocol version adds a handshake, stable machine identity, per-device credentials, capability negotiation, provider/target identifiers, resumable event cursors, bounded frames, and a typed error taxonomy. Until then, changes to the contract above require corresponding host tests and native-client compatibility fixtures.
