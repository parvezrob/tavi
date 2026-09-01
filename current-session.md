# Current session

> Every agent starts here. This file holds the live state of the project *right now* and the next piece of work. Update it before ending a session (or at any significant milestone); move the previous state into [`handoffs.md`](./handoffs.md). Keep it short — details belong in the linked docs.

**Last updated:** 2026-09-02 ~04:30 (session closed after a long night with Fable 5.1: home v3, offline/attach fixes, Files on the phone, `tavi` command, tests green; owner compacts and starts #58 next)

## Next work

**#58 — private dev-server preview: an agent starts something on `localhost:<port>` on the Mac or robin-PC and the owner sees it on the phone, privately.** Sanctioned: FEATURE_LANDSCAPE "Local dev-server preview" (Next), PRD §8. Product line: private forwarding through the host over the same Tailscale connection the phone already uses; a WebKit view on the phone; **no public tunnel, ever**. **Owner asked for a short plan before any code** (2026-09-02): the design questions are (1) how the phone reaches a port on the host — a host-side reverse proxy under `/api/preview/<port>/…` behind the bearer token vs. a per-session forwarded port; WebKit cannot add an `Authorization` header to every sub-request, so a token-in-cookie or a short-lived signed path is needed; (2) which ports may be exposed — only ports bound to localhost by a process the agent's pane owns, or an allowlist the person confirms once; (3) how a port is discovered — scan the agent's pane for `localhost:\d+` (the same transcript scanner as Files mentioned) vs. `lsof` on the host. Write the plan to the issue, get the owner's call, then build host first (routes + tests), phone second (a Preview entry beside Files), verify by looking.

**After #58:** #59 worktrees (create from the phone; which agent lives in which tree; also where "changes since branching from main" would land — Files shows uncommitted work only). #54 P3 brand moments whenever a light session fits. #37 App Store epic gates any submission. #39 test seam: the two Claude-permission live tests (`testNeedsYouSurvivesVisitingTheBlockedAgent`, `testAnswerWaitingPermissionFromNeedsYouCard`) skip whenever the owner's Claude auto-allows Bash — stage them through `POST /api/hooks/claude` to make them deterministic.

**Design pages from this stretch (for reference):** home v3 before/after https://claude.ai/code/artifact/2a2d609e-d2bd-418e-b55a-b7621823a098 · the three calls (all decided per the leans) https://claude.ai/code/artifact/c7b31825-b308-4c49-9301-fa4f8bffd3cc.

**Working rules learned tonight (also in AGENTS.md / docs):** the owner's Mac *is* the host — no full suites or device builds on it while the owner is on the phone; keep the host quiet during live suites (a mid-suite redeploy skipped two tests). Say `npx tavi-host <cmd>` in docs for npx installs unless the `tavi` shim is known to be there; the bare `npx tavi` is a stranger's package.

**Publishing rule (owner + agent, 2026-09-01):** the agent bumps `apps/host/package.json` + `src/config.ts` `VERSION` only when it says a release is worth publishing; the owner runs `cd apps/host && npm publish` in Terminal.app (2FA; the auth URL is masked under Claude Code). Versions are immutable ("cannot publish over the previously published versions" = already up), propagate in 1–2 min, and every publish restarts every paired host.

**Open owner decisions:** whether phones should stop accepting the shared host token; a hosted relay opt-in for people who bounce off Tailscale (docs/PRODUCT.md principle 2 says direct only; decide after testers); GitHub Actions publish job.

## Live state

- **Product:** Tavi by Farfield (Terminal Agent Vantage and Intervention). Repo `parvezrob/tavi`, checkout `~/Projects/tavi`. Host package `tavi-host` **0.1.12** on npm = the checkout (Apache-2.0; everything else © Farfield). Quick start `npx tavi-host pair`; after it, `tavi doctor` / `update` / `devices [revoke]` / `uninstall` work from any terminal (the shim `pair` adds, #64).
- **Owner Mac:** host runs from the checkout as launchd `com.farfield.tavi.host` (deploy: `cd apps/host && npm run build && npm run service:install`, then `/api/health` → 0.1.12 now); herdr 0.8.2 under `brew services start herdr` (headless); Claude hooks installed; the owner's Claude currently auto-allows Bash (permission dialogs are rare).
- **Owner ubuntu (`robin-PC`):** paired; runs the published host (self-updates daily; `tavi update` after the shim). Needs one more `npx tavi-host pair` to get the `tavi` command.
- **Phone:** iPhone 12 Pro runs the `03:20` build of `c0ee399`+ (home v3, offline fix, Files); free-Apple-ID profile expires **2026-09-08** — rebuild with `-allowProvisioningUpdates` into `-derivedDataPath` separate from the simulator's and `xcrun devicectl device install app`. Both computers paired.
- **Simulator:** iPhone 17 Pro `3CA94743-421A-4866-BD4F-2A92149AFE82`. Two-computer home without a second machine: `TAVI_DEV_HOST="<mac>,<mac>:443"` + `TAVI_DEV_HOST_NAMES="MacBook Air,robin-PC"`; audit captures under `TEST_RUNNER_TAVI_AUDIT=1` (`TaviScreenshotAudit`, incl. `testCaptureChangedFilesAndDiff` with `TEST_RUNNER_TAVI_AUDIT_CWD`).
- **Suites:** host 184 tests (`npm test`, `npm run check` is the type gate, `npm run build`); iOS 121 unit tests + live UI suite (139 total with UI; last full run 131 passed, 2 fixed since, 6 skips explained). Live UI tests need `TEST_RUNNER_TAVI_DEV_HOST/TOKEN` exported (token: `npm run -s token` in apps/host). Verification rule: for anything a person sees, look.
- **Host ↔ herdr:** protocol ≥ 17 + `agent.list` shape gate; `herdr agent attach <pane> --takeover` always; herdr refuses `agent.send_keys` to a shell pane seconds old (tests type through the app's surface); pane size is last-writer-wins, hand-back to the desktop waits `DETACH_GRACE_MS` 8 s (#63).
- **Phone ↔ host health:** `AgentDirectory.health` connecting/live/stale/offline/revoked; "Connecting…" bounded to 5 s then probe → Offline sticky across foregrounds; retries back off 2 → 30 s.
- **Files (#25 #57 #61, PRD §7.10):** `/api/changes`, `/api/changes/file`, `/api/files{,/stat,/content,/raw}` — realpath **then** roots, secrets by name; phone `Features/Files/`.
- Open issues: #27–#29 (parked), #37 epic, #39 test seam, #47 (acceptance timing only), #49 WSL2 doc, #52 polish, #54 P3, #58 next, #59.
