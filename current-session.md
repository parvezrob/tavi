# Current session

> Every agent starts here. This file holds the live state of the project *right now* and the next piece of work. Update it before ending a session (or at any significant milestone); move the previous state into [`handoffs.md`](./handoffs.md). Keep it short — details belong in the linked docs.

**Last updated:** 2026-08-25

## Next work

**Phase C of [`docs/ROADMAP.md`](./docs/ROADMAP.md) — the real app surface.** File a GitHub issue per item before coding (AGENTS.md). Read `docs/PRD.md` §7 and `docs/V1_SCREEN_AND_NAVIGATION_MAP.md` before UI work. **Owner decision (2026-08-25):** the mockups (`docs/assets/agent-deck-v1-home-terminal.png`) are *reference*, not spec — the implementing agent has design latitude to deliver a premium, performant, polished UI, bounded by PRD §7.1 (dark-first, Orca-clean) plus iOS HIG and App Store review readiness.

1. Sessions home: `Needs you` / `Active` / `Recent` cards — identity, state colors, freshness, safe preview. Backing endpoints already live: `/api/events` feed (AgentDirectory on iOS mirrors it), `GET /api/agents/{pane}/preview`.
2. Focused terminal screen: header identity + `Jump to` sheet over the Herdr workspace → tab hierarchy (needs a host endpoint over `workspace.list`/`tab.list`).
3. Multiline composer with deliberate send — `POST /api/agents/{pane}/prompt` is live; note the text **appends** to whatever is typed in the agent's composer. Plus completed quick-key row (Shift-Tab, Ctrl modifier, Enter).
4. Terminal ergonomics: font size, selection/copy-paste, scroll feel tuning (issue #10), hardware keyboard.

**Exit gate:** founder dogfood entirely from the phone — median under 5 s from app open to the correct session; 20 real interventions without the laptop.

## Live state

- Phases A (reliability) and B (Herdr control plane) are **complete**; all gates passed live on the physical iPhone. See ROADMAP for what shipped per phase.
- Host runs as the launchd service on the latest build; the phone has the latest app build. Deploy procedure and verification loop: [`docs/DEVELOPMENT.md`](./docs/DEVELOPMENT.md).
- Herdr contract and traps: [`docs/HERDR_INTEGRATION.md`](./docs/HERDR_INTEGRATION.md). Transport spec: [`protocol/README.md`](./protocol/README.md).
- Open issues: #8 (old PWA recovery, unrelated), #10 (scroll feel — Phase C item 4). Everything else is closed.
- Known quirks to keep in mind: phone connection settings are the dev AppStorage form until Phase D (QR + Keychain); while a phone is attached a pane clamps to phone width on the Mac (restores instantly on detach); `herdr-events.test.ts` has a rare timing flake.
