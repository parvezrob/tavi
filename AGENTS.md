# Mocha agent rules

Keep this file lean. It routes work and protects shared boundaries; detailed engineering policy lives in linked sources.

## Start here

- **Read [`current-session.md`](./current-session.md) first** — the live project state and the next piece of work. Recent context: [`handoffs.md`](./handoffs.md).
- Always read [`README.md`](./README.md) and [`docs/DEVELOPMENT_PRINCIPLES.md`](./docs/DEVELOPMENT_PRINCIPLES.md).
- Read only task-relevant sources: product behavior → [`docs/PRD.md`](./docs/PRD.md); execution → [`docs/IMPLEMENTATION_PLAN.md`](./docs/IMPLEMENTATION_PLAN.md); host/client contract → [`protocol/README.md`](./protocol/README.md); rich agent UI → [`docs/CHAT_UI_AND_AGENT_ARCHITECTURE.md`](./docs/CHAT_UI_AND_AGENT_ARCHITECTURE.md).
- Inspect `git status` and active GitHub issue/PR state before editing. Preserve unrelated and in-flight work.

## Product and engineering boundaries

- Mocha is a native SwiftUI client plus a local API-only host. Do not reintroduce a web client, hosted relay, or agent harness without an explicit product decision.
- The universal fallback is a durable tmux terminal over the versioned host protocol. Provider integrations are optional, capability-gated adapters.
- Treat pairing credentials as shell access. Never commit or log secrets, tokens, prompts, terminal contents, or private files.
- Clean, readable, reusable production code is mandatory. Follow SOLID, correct ACID boundaries, strict Swift concurrency, explicit ownership, and the repository definition of done.
- Reuse before creating. Add a shared abstraction only after a second real consumer proves the boundary.

## Multi-session workflow

- GitHub Issues are the work queue and the only known-issue tracker. Do not create a local bug ledger or shadow backlog. The one sanctioned session record (owner decision, 2026-08-25) is `current-session.md` + `handoffs.md`: update `current-session.md` before ending a session, move the superseded state into `handoffs.md`, and keep both short — bugs and work items still go to Issues, durable knowledge still goes to `docs/`.
- Every implementation change or known defect starts with an issue containing scope and testable acceptance criteria. Read-only research and owner-requested documentation may proceed without one.
- Before editing, claim the issue and name the paths you expect to own. Agents must not share a branch or concurrently edit overlapping files. Coordinate overlap in the issue before continuing.
- **MVP fast track:** until the owner declares the MVP gate complete, one active integration session may commit issue-scoped work directly to `main` after all local gates pass, then push and verify the applicable remote CI. Parallel sessions use isolated branches/worktrees and hand commits to that integrator.
- GitHub-hosted CI runs host checks only. Do not build GhosttyKit or the iOS app on hosted CI without explicit owner approval; run native build/test gates locally and on physical devices.
- **After MVP:** one issue has one active owner, one short-lived branch/worktree, and one PR. Use `codex/<issue>-<slug>` for Codex branches; other agents use their own prefix. Let CI pass and leave merging to the repository owner unless they explicitly ask otherwise.
- Keep `main` releasable in both modes. Never force-push or rewrite shared history.
- Use focused conventional commits such as `feat:`, `fix:`, `test:`, `docs:`, or `chore:`.

## Repository structure

- `apps/host/` — local Node host, tmux, PTY, transport, and provider adapters.
- `apps/ios/` — native Xcode workspace, app, Swift packages, and iOS tests.
- `protocol/` — cross-client schemas, compatibility fixtures, and protocol documentation.
- `docs/` — maintained product, architecture, research, and visual decisions only.
- `scripts/` — reproducible repository/build tooling; no one-off personal automation.
- Keep tests beside their owning module. Put a fixture in `protocol/` only when multiple implementations consume it.
- Do not create speculative top-level folders or empty architectural layers. Add a directory with its first real owned artifact.

## Finish work

- Run the narrowest relevant test first, then `npm run check`, `npm test`, and `npm run build` for host changes. Native changes require the relevant Xcode tests and a physical-device check when lifecycle, terminal, networking, input, or performance is involved.
- Update the authoritative contract or decision in the same change; avoid duplicate summaries.
- Put every newly discovered out-of-scope defect into a GitHub issue before finishing. Reference follow-up issues in the PR rather than adding TODO documents.
- Report outcome, verification, risks, and follow-ups. Never claim completion with failing or skipped required checks.
