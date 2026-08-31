# Product direction (early note)

> This document records the first product direction. The maintained product source of truth is now [`README.md`](./README.md), with the full research baseline in [`RESEARCH_AND_STRATEGY.md`](./RESEARCH_AND_STRATEGY.md) and release requirements in [`PRD.md`](./PRD.md). Where they disagree, the newer documents win.

## The job

When away from a computer, open one fast surface, see every active coding session, understand which machine and project it belongs to, send a prompt or control key, then leave without disrupting the process.

## Principles

1. **Terminal-compatible, not agent-aware.** Mocha should never decide how an agent thinks or works.
2. **Direct connection.** The default path is phone → private network → computer, with no relay account.
3. **Disconnect is normal.** Backgrounding the phone must not affect the session.
4. **Typing is the expensive action.** Mobile controls optimize for sending prompts, paste, interrupt, tab, escape, and arrow keys.
5. **Native quality.** The iOS client standardizes on SwiftUI plus a pinned GhosttyKit/Metal terminal while keeping rendering independent from the host protocol.

## MVP

- Pair and switch between multiple computers.
- Discover configured project folders.
- Launch Codex, Claude Code, a shell, or a custom command.
- List and attach to existing Herdr agents.
- Preserve terminal state across mobile disconnects.
- Reconnect automatically after network changes.
- Provide a multiline prompt composer and terminal control row.
- Run the host automatically after macOS login.

## Next slices

1. Push notifications based on explicit terminal bell / OSC signals, not output scraping.
2. A lightweight file diff and approval view alongside the raw terminal.
3. Camera/file upload into the current working directory with an explicit confirmation.
4. Linux systemd and Windows service installers.

## Explicit non-goals

- A model router, prompt framework, or agent runtime.
- Reimplementing vendor conversation storage.
- Parsing terminal output to invent unreliable “thinking” states.
- A mandatory hosted relay.
- Public internet exposure by default.
