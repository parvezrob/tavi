# Tavi host protocol

**Status:** current prototype contract
**Protocol:** `tavi.v1`
**Updated:** 2026-08-31

This document preserves the transport contract used by the native Tavi client. It is platform-neutral and is the compatibility baseline while the protocol evolves toward versioned capability negotiation.

## Transport and trust boundary

- The host listens on `127.0.0.1:8787` by default.
- Tailscale Serve provides tailnet-only HTTPS and WebSocket access.
- Do not expose the host directly to the public internet or through Tailscale Funnel.
- Every protected HTTP request and terminal connection requires the per-host token.
- Treat the token as shell access. The current token is a bootstrap-era credential, not the final per-device pairing design.
- JSON response bodies use UTF-8. Successful responses and errors are not cacheable.

### Namespace migration (Mocha → Tavi, 2026-09-01, #62)

- Active runtime identifiers use `tavi`: `TAVI_*`, `~/.tavi`, `tavi-*`, the pairing URL scheme `tavi://pair`, and the WebSocket subprotocols `tavi.v1` / `tavi.v2` / `tavi.events.v1`. The previous spelling was `mocha.*`; there is no negotiation between the two, so a host and an app must be upgraded together.
- On first start, an existing `~/.mocha` directory is moved to `~/.tavi` in one rename (token, paired devices, host identity, log) so no phone has to re-pair. If both directories exist with different tokens, startup stops with an actionable error — the host never guesses which shell-access credential is authoritative.
- `MOCHA_*` environment variables still apply when the matching `TAVI_*` is unset (a service plist written before the rename exports them) and are reported once at startup; `npm run service:install` rewrites the plist. The launchd label moved from `com.parvezrob.mocha.host` to `com.farfield.tavi.host`; install boots the old label out and removes its plist.

## HTTP authentication

Two kinds of bearer credential are accepted everywhere: the host's own token (`~/.tavi/config.json`, shown by `npm run token`; the CLI and pre-pairing dev flow) and any **paired device credential** minted by the pairing exchange below. Only the host token may start a pairing. Revoking a device on the host (`tavi devices revoke <id|name>`) invalidates its credential immediately.

Send the credential on every `/api/*` request except health and `POST /api/pair`:

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

### `POST /api/pair/begin`

Host-token only. Mints a single-use pairing secret that expires in 5 minutes (at most 5 may be outstanding; `429` beyond that). This is what `tavi pair` calls before printing the QR.

```json
{ "secret": "…", "expiresAt": "2026-08-31T12:00:00.000Z", "host": { "name": "studio-mac", "fingerprint": "8F2A 19C4 · 7B10 D6E9" } }
```

### `POST /api/pair`

**Unauthenticated.** Redeems a pairing secret for a device credential. The QR carries `tavi://pair?u=<https url>&s=<secret>&f=<fingerprint>&n=<host name>`; the phone shows `n`/`f` for the person to confirm against the Mac before calling this.

```json
{ "secret": "…", "deviceName": "Parvez's iPhone" }
```

`201` → `{ "credential", "device": { "id", "name", "pairedAt" }, "host": { "name", "fingerprint" } }`. The credential is returned exactly once; the host stores only its hash. A client must refuse to keep the credential if `host.fingerprint` differs from the QR's `f`. `401` for an unknown, spent, or expired secret.

### `GET /api/devices`, `DELETE /api/devices/{id}`, `DELETE /api/devices/me`

Host-token only: list paired devices (`{ "devices": [{ "id", "name", "pairedAt", "lastSeenAt"? }] }`) and revoke one (`204`, or `404`). A paired phone may call `DELETE /api/devices/me` with its own credential to unpair itself (`204`); the host token gets `400` there. Revocation is immediate: open event streams and terminals for that device close with WebSocket code `4401` within two seconds.

### `GET /api/host`

```json
{
  "name": "Studio Mac",
  "platform": "darwin",
  "arch": "arm64",
  "version": "0.1.0",
  "fingerprint": "99F5 7AF0 · E678 C534"
}
```

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

`recent` merges the folders agents are running in right now (`active: true`) with the folders this host has previously launched an agent in. Folders with a live agent come first, then the most recently chosen; `lastUsedAt` is absent for a folder known only from a live agent, and a remembered folder that no longer exists on disk is omitted rather than offered. `name` is the folder's basename. `withinRoots` says whether the folder sits inside `roots`, so a client can mark the folders whose creation will require the confirmation described below instead of discovering it after a failed request. `workspaces` is the configured roots and their immediate visible child directories, Git roots first.

`roots` may be empty — a host with none of the default project directories and no `TAVI_ROOTS` configures no roots at all, and then *every* create requires the confirmation below. Path comparison is case- and Unicode-normalization-insensitive, matching the default macOS filesystem.

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

**Compatibility.** Requiring `cwd` is a breaking change to this endpoint, made while Tavi is pre-MVP with a single first-party client shipped alongside the host. A client that omits `cwd` gets `400` on every create and must be updated with the host; there is no negotiated fallback. Deploy the host and the app together.

### `PATCH /api/herdr/tabs/{tabId}`

Renames a Herdr tab (#55) — the user's own name for the task the pane is doing.

```json
{ "label": "ship the fix" }
```

`label` is trimmed and must be 1–120 characters after trimming (`400` otherwise). The host wraps `tab.rename`; Herdr owns the truth, and the applied label reaches every client through the agents feed — each agent in `GET /api/agents` (and the events snapshots) carries the tab's current label as `tabLabel` when the tab has one. Clients decide which labels are user-meaningful; Herdr's defaults (bare numbers, `tavi <kind>` on phone-created tabs) are not identity.

| Status | Meaning |
| --- | --- |
| `200` | Renamed; body is `{ "renamed": true, "tabId", "label" }`. |
| `400` | Missing, blank, or over-long `label`. |
| `404` | Herdr is not configured on this host. |
| `503` | Herdr is configured but could not rename the tab. |

### `GET /api/changes?cwd=…` — what an agent changed (#25)

Read-only view of the uncommitted work in the git repository that contains `cwd` (an absolute path inside the configured roots; `403` + `{ "outsideRoots": true }` otherwise, `404` + `{ "notRepository": true }` when no repository contains it). Response:

```json
{ "repository": "/Users/me/Projects/app", "branch": "main", "truncated": false,
  "files": [{ "path": "src/a.ts", "code": " M", "state": "modified", "staged": false, "unstaged": true, "additions": 2, "deletions": 1, "secret": false },
            { "path": "renamed.txt", "code": "R ", "state": "renamed", "from": "old.txt", "staged": true, "unstaged": false, "secret": false }] }
```

`state` is one of `modified`, `added`, `deleted`, `renamed`, `untracked`, `conflict`, `other`; `path` is relative to `repository`. Counts are working tree vs `HEAD` and absent for binary files. `secret: true` marks a file the redaction rule refuses to show (by name: `.env*`, `*.pem`, `*.key`, `id_rsa*`, anything with `credentials`/`secret`, `.npmrc`/`.netrc`/`.pypirc`) — listed, never diffed. At most 500 files (`truncated`). Three fixed git invocations run under `execFile` with a timeout; no mutating git operation exists on this path.

### `GET /api/changes/file?cwd=…&path=…` — one file's diff

`path` is a `files[].path` from `/api/changes`. Unified diff of the working tree against `HEAD` (staged and unstaged together); untracked files come back as all additions. `{ "path", "diff", "truncated", "binary" }`; the diff is cut at 256 KB on a line boundary and marked `truncated`. `400` for a path that leaves the repository, `403` for a secret, `404` when git knows no such file.

### `GET /api/files…` — read-only files (#57, #61)

All four routes take `cwd` (absolute) and `path` (absolute, or relative to `cwd`). Resolution is: join, **`realpath`**, then containment against the configured roots (themselves realpath'd) — a symlink that points out of a root is refused *after* realpath, which is the rule that makes "nothing outside the roots is reachable" true. Refusals: `403` + `{ "outsideRoots": true }` for anything outside (existing or not — the host says nothing more), `403` for anything under a `.git` directory, `404` for a missing file inside the roots, `400` for a malformed path.

- `GET /api/files/stat` → `{ "path", "relativePath", "name", "kind": "file"|"directory"|"other", "size", "modifiedAt", "preview": "text"|"image"|"pdf"|"binary"|"secret"|"directory", "mime" }`. The phone uses this to keep only real, showable files in "Files mentioned".
- `GET /api/files` → a directory listing: `{ "path", "relativePath", "truncated", "entries": [{ "name", "kind", "size", "ignored", "preview" }] }` — folders first, then files, alphabetical; `.gitignore`d entries last with `ignored: true`, dimmed on the phone and never hidden. `.git` is listed but nothing under it opens. At most 2 000 entries. `400` when `path` is a file.
- `GET /api/files/content` → text: `{ "path", "relativePath", "size", "mime", "encoding": "utf-8"|"utf-16le"|"utf-16be"|"latin1", "content", "truncated", "lines" }`. Over 1 MB is cut on a line boundary and marked. Refused with `{ "error", "preview", "size", "mime" }`: `400` for a folder, `403` for a secret (rule above), `415` for binary — the phone says "binary, 2.3 MB" instead of rendering garbage. Binary is a first-8 KB NUL sniff, with UTF-16 BOMs recognised as text.
- `GET /api/files/raw` → the bytes of an image or PDF with its `Content-Type`, up to 16 MB (`413` beyond; `415` for anything that is not an image or PDF). Never text.

Nothing under `/api/files` or `/api/changes` writes, renames, deletes, or runs anything but the fixed git reads above.

## Terminal WebSocket

Connect to:

```text
wss://<tailnet-host>/api/agents/{paneId}/terminal
```

`paneId` is a herdr pane id from `GET /api/agents` (1–128 characters from `A-Z`, `a-z`, `0-9`, `_`, `.`, `:`, `-`). The host attaches through `herdr agent attach`; herdr owns the durable pane and its process.

Send the access token in the standard authorization header:

```http
Authorization: Bearer <token>
```

Offer only the `tavi.v1` WebSocket subprotocol. The server must select that exact protocol; a missing or unsupported protocol returns HTTP `400` before pane lookup or PTY creation. Authentication failure returns `401`, an unknown pane returns `404`, and a Herdr that is not running returns `503` before upgrade.

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

`signal` is optional. Unknown or malformed messages return an `error` without writing to the PTY. A normal PTY exit closes the socket with code `1000`. Failure to open the terminal closes with code `1011`. Closing the socket ends only the temporary attachment PTY; herdr continues to own the durable pane and its child process.

The shared compatibility fixtures live in [`fixtures/terminal-v1/`](./fixtures/terminal-v1/). They are synthetic and contain no captured prompts, terminal contents, credentials, or private paths.

## Terminal WebSocket v2 (`tavi.v2`)

Clients should offer the `tavi.v2` subprotocol; the server prefers it and falls back to `tavi.v1` when only that is offered. v2 changes output delivery and reconnect semantics; client messages (`input`, `resize`, `ping`) and the `pong`/`exit`/`error` server messages are unchanged and remain JSON text frames.

### Persistent attachment

The host keeps one PTY attachment per session that survives WebSocket drops. After the last client disconnects the attachment is retained for a bounded window (default 120 s) and its output accumulates in a ring buffer (default 1 MiB) tagged with absolute byte offsets. Each attachment has a random `stream` epoch token; offsets are meaningful only within one epoch. Only one client owns an attachment at a time — a new connection to the same session supersedes the previous one, which receives an `error` and close code `1000` (`superseded`).

### Ready and resume

The v2 `ready` message carries the stream epoch and the client's starting offset:

```json
{ "type": "ready", "stream": "0d5f…", "offset": 0, "resumed": false }
```

To resume after a drop, reconnect with query parameters:

```text
wss://<host>/api/agents/{paneId}/terminal?stream=<epoch>&resume=<offset>
```

where `offset` is the absolute offset one past the last byte the client has rendered. On a hit (`resumed: true`) the host replays exactly the missed bytes — no gap, no duplication. On any miss (attachment gone or exited, epoch mismatch, offset trimmed out of the ring) the host discards the old attachment, spawns a fresh attach (herdr repaints the full pane), and answers `resumed: false` with a new `stream` and `offset` — the client must reset its offset counter to `offset`.

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
