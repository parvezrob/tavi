# Tavi agent rules

Keep this file lean. It routes work and protects shared boundaries; detailed engineering policy lives in linked sources.

## Start here

- **Read [`current-session.md`](./current-session.md) first** — the live project state and the next piece of work. Recent context: [`handoffs.md`](./handoffs.md).
- Always read [`README.md`](./README.md) and [`docs/DEVELOPMENT_PRINCIPLES.md`](./docs/DEVELOPMENT_PRINCIPLES.md).
- Read only task-relevant sources: product behavior → [`docs/PRD.md`](./docs/PRD.md); execution → [`docs/IMPLEMENTATION_PLAN.md`](./docs/IMPLEMENTATION_PLAN.md); host/client contract → [`protocol/README.md`](./protocol/README.md); rich agent UI → [`docs/CHAT_UI_AND_AGENT_ARCHITECTURE.md`](./docs/CHAT_UI_AND_AGENT_ARCHITECTURE.md).
- Inspect `git status` and active GitHub issue/PR state before editing. Preserve unrelated and in-flight work.

## Product and engineering boundaries

- Tavi is a native SwiftUI client plus a local API-only host. Do not reintroduce a web client, hosted relay, or agent harness without an explicit product decision.
- Every agent is reachable as a real terminal over the versioned host protocol; herdr is the only backend (the tmux lane was removed in #53). Richer semantics are optional, capability-gated adapters on top.
- Treat pairing credentials as shell access. Never commit or log secrets, tokens, prompts, terminal contents, or private files.
- Clean, readable, reusable production code is mandatory. Follow SOLID, correct ACID boundaries, strict Swift concurrency, explicit ownership, and the repository definition of done.
- Reuse before creating. Add a shared abstraction only after a second real consumer proves the boundary.

## Multi-session workflow

- GitHub Issues are the work queue and the only known-issue tracker. Do not create a local bug ledger or shadow backlog. **No shadow knowledge anywhere, including assistant memory** (owner decision, 2026-09-02): an assistant's persistent memory may hold nothing but a pointer to this repository — every fact, preference, machine detail, and working agreement lives in the repo (`docs/`, [`docs/OWNER_ENVIRONMENT.md`](./docs/OWNER_ENVIRONMENT.md), this file). The one sanctioned session record (owner decision, 2026-08-25) is `current-session.md` + `handoffs.md`: update `current-session.md` before ending a session, move the superseded state into `handoffs.md`, and keep both short — bugs and work items still go to Issues, durable knowledge still goes to `docs/`.
- Every implementation change or known defect starts with an issue containing scope and testable acceptance criteria. Read-only research and owner-requested documentation may proceed without one.
- **Sub-agents (owner decision, 2026-09-03):** an orchestrating session may hand issue-scoped packages to Opus 5 sub-agents in isolated worktrees, one package per non-overlapping set of files, with a strict brief (scope, acceptance, "no new abstractions, comments only for why"). The loop (owner's, 2026-09-03): the implementer reports done → **two cold-context Opus 5 verifiers** read the issue and the diff independently (one for correctness and scope — exactly the acceptance, no behaviour change; one for quality — over-engineering, narrating comments, style drift) → findings go back to the implementer, verifiers re-check → the orchestrator then reads the diff, runs the gates, and commits. A sub-agent's "done" is a claim, not a result. Sub-agents never commit to `main`.
- Before editing, claim the issue and name the paths you expect to own. Agents must not share a branch or concurrently edit overlapping files. Coordinate overlap in the issue before continuing.
- **MVP fast track:** until the owner declares the MVP gate complete, one active integration session may commit issue-scoped work directly to `main` after all local gates pass, then push and verify the applicable remote CI. Standing permission (owner, 2026-08-24): commit each verified logical unit without asking — host and iOS in separate scoped commits — then push `main` and check `gh run list`. Parallel sessions use isolated branches/worktrees and hand commits to that integrator.
- GitHub-hosted CI runs host checks only. Do not build GhosttyKit or the iOS app on hosted CI without explicit owner approval; run native build/test gates locally and on physical devices.
- **After MVP:** one issue has one active owner, one short-lived branch/worktree, and one PR. Use `codex/<issue>-<slug>` for Codex branches; other agents use their own prefix. Let CI pass and leave merging to the repository owner unless they explicitly ask otherwise.
- Keep `main` releasable in both modes. Never force-push or rewrite shared history.
- Use focused conventional commits such as `feat:`, `fix:`, `test:`, `docs:`, or `chore:`.
- **Verification ladder** (owner correction, 2026-09-01): compile first (`xcodebuild build`; for the host `npm run build` — tsx runs tests without typechecking, so tsc is the only type gate), then targeted `-only-testing:` runs for touched behavior, then **one** full suite as the final gate. Never full-suite-first: the simulator is a serial resource, and mid-run edits invalidate a run. Keep the host quiet during live suites — disposable-pane experiments mid-suite have caused false failures. **And the converse (owner-felt, 2026-09-02): the owner's MacBook Air *is* the host.** A full simulator suite plus a device build on it pushed the 15-min load to 12 on 8 cores; the phone the owner was typing on stalled, flapped, and came back with a garbled Claude transcript, and the typing-echo test failed for the same reason. Run live suites and device builds only when the owner is not on the phone, or after saying so; a targeted `-only-testing:` run is fine.
- **For anything a person sees, verify by looking** (owner rule, learned three times on 2026-08-31): a screenshot (`xcrun simctl io <udid> screenshot` against the live host) or the exact strings the other side produces — green suites have missed visible breakage. The owner judges screens from the real phone and compares against the references in `docs/assets/` (Orca, T3 Code, the v1 mockups); calm, organized, reference-grade layouts are part of done.

## Repository structure

- `apps/host/` — local Node host, herdr adapter, PTY bridge, transport.
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
