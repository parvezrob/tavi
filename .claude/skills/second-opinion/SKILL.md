---
name: second-opinion
description: Get a cold-context second opinion from GPT (Codex CLI) on a plan, contract, diff, or design before committing to it. Packages the shell-out mechanics — model choice, read-only sandbox, verdict-line prompt — so any session can invoke it without remembering flags.
allowed-tools:
  - Bash(codex *)
  - Bash(git *)
  - Bash(cat *)
---

# Second opinion via GPT (Codex CLI)

Shell out to a GPT model for a cold-context review. The value is exactly that the reviewer has
NOT been in this session: no context fatigue, no investment in the plan, no shared blind spots —
it reads the artifact cold and asks whether it holds up. Use it before locking a plan/contract,
after a significant implementation, or whenever two Claude passes agree a little too easily.

## Step 1: Pick the model (roster in workflow.md — defaults, not limits)

- `gpt-6-astra` — **the default for every review in this skill** (owner directive 2026-09-06:
  "use gpt6 astra from now on instead of gpt-5.6 sol"). Plan reviews, contract locks, and
  code reviews all go here. Verified 2026-09-06 with codex-cli 0.153.4: `codex exec -m gpt-6-astra`
  answers and identifies as GPT-6; efforts low/medium/high/xhigh/max/ultra are listed for it in
  `~/.codex/models_cache.json`. Keep `xhigh` (Step 3); `ultra` delegates sub-tasks on its own and
  is not a review posture.
- `gpt-5.6-sol` / `gpt-5.6-terra` / `gpt-5.6-luna` — the previous roster; still installed. Use
  one only when the owner asks for a different-vendor-family seat or astra is unavailable (a
  400 on the model id).

Model ids are dated observations (2026-09); if a run 400s, re-verify ids against the installed
CLI (`python3 -c 'import json;[print(m["slug"]) for m in json.load(open("$HOME/.codex/models_cache.json"))["models"]]'`
lists what the CLI knows) before concluding anything.

## Step 2: Build a SELF-CONTAINED prompt

The reviewer starts cold — the prompt must carry everything:

- **What to review** (repo-relative path, or a commit range like `git diff main...HEAD`).
- **What it is** (contract / plan / diff / design) and which repo rules govern it (point at
  AGENTS.md §N, the relevant skill, or the locked contract).
- **What to verify adversarially** — enumerate; "review this" produces mush.
- **Severity vocabulary**: BLOCKER / HIGH / MEDIUM / LOW (canonical, per workflow.md pipeline).
- **A machine-findable last line**: `then last line exactly: VERDICT: <APPROVE|NOT APPROVED>` (or
  LOCKABLE/NOT LOCKABLE for contracts).

## Step 2.5: Seat count — the v2 round structure (ADR-059)

Contract chains: r1 = 2–3 parallel seats with DISTINCT lenses (one MUST run commands /
open sources) → confirmation seat → lock on LOCKABLE only, then the bounded frozen-head
terminal path. Implementation: r1 = 3 seats → 1 fold-audit → STOP → ONE closing cold
seat, different vendor than the implementer, that has NOT participated in the chain, on
the final head after the CI-parity battery. Lenses for the r1 seats:

- **fold-audit** (confirmation/fold-verify rounds) — did the folds land; fix-the-fix
  defects (this lens has caught fold regressions in every chain it ran in);
- **fresh-eyes** — whole artifact cold, no knowledge of prior rounds;
- **security / domain lens** — F-row wording, operational posture, or the artifact's
  highest-risk axis as its own dedicated seat;
- **code-health** — for implementation diffs: the seat reads
  ENGINEERING_GUIDELINES §2a (the code-health constitution) first, then audits the diff against its three
  health questions (stranger-readable · survives change · every line carries signal) and
  its slop classes (`header:` `comment:` `types:` `suppress:` `dead:` `abstraction:`
  `defensive:` `duplicate:` `test:` `naming:`). Findings are one line each, tagged; the seat ends with
  an explicit verdict per question (`readable: yes/issues · change-safe: yes/issues ·
  signal: yes/issues`) — never a bare line count. Every implementation-approval round
  carries this lens (owner directive 2026-08-21) — as its own seat in multi-seat rounds,
  or folded into the single seat's brief in taper rounds.

Single-seat is for trivial/bounded confirmations only. Parallel `codex exec` runs work
(proven 2026-07-27 tri-seat: three seats independently caught a fold-introduced PII-log
HIGH); launch them concurrently and disposition the union of findings. Liveness policy
for parallel seats = the single policy in Step 3: completion notifications by default;
an optional watchdog runs ONE per seat, on that seat's own home.

## Step 3: Run it

```bash
codex exec -m gpt-6-astra -s read-only \
  -c model_reasoning_effort=xhigh \
  --output-last-message /tmp/second-opinion.md \
  "<self-contained prompt>" < /dev/null
```

- **Reasoning effort is ALWAYS `xhigh` by default** (owner directive 2026-07-28): pin it
  explicitly with `-c model_reasoning_effort=xhigh` — never rely on `~/.codex/config.toml`
  happening to set it. Deviate only on an explicit owner instruction for that run.

- **`< /dev/null` is load-bearing for background runs** (observed on first invocation,
  2026-07-24): with a non-TTY stdin pipe, `codex exec` prints
  `Reading additional input from stdin...` and blocks forever waiting for EOF — the review
  never starts. Closing stdin costs nothing in foreground runs; always include it.

- **Always `-s read-only`** for reviews — the second model reviews; it never rewrites
  (implementation shell-outs are a separate, owner-approved decision, not this skill).
- `--output-last-message <file>` — stdout is hook-noisy; the file holds the verdict. Read it
  with `cat`.
- Runs can exceed 10 minutes — set a generous Bash timeout or run in the background.
- **A healthy astra/sol run finishes in ~10 min; treat silence past ~15 as a hang, not depth**
  (environment-specific heuristic observed on this machine, not a guaranteed liveness signal).
  Liveness check: the newest `~/.codex/sessions/<date>/rollout-*.jsonl` must keep growing
  during a live review — a file that wrote its header and froze is a dead run (kill + retry).
  Known stall source (observed 2026-07-24): `~/.codex/config.toml` is the ChatGPT desktop
  app's config, so every `codex exec` boots its plugin/MCP stack (`node_repl` inside
  ChatGPT.app, 120s startup timeout, notify hooks — the `--dangerously-bypass-hook-trust`
  warnings in output come from this); a hung plugin startup looks exactly like a frozen run.
- **Liveness policy (ONE policy, 2026-08-25 — supersedes every older watchdog rule in
  this file):** background-task completion notifications are the default signal — no
  watchdog required. If a run has no notification channel, arm AT MOST this script,
  one instance per seat (it exits silently when the verdict file lands, alerts on a
  3-min freeze):

  ⚠ The watchdog must watch the SAME home the run uses: with minimal `CODEX_HOME`
  isolation (below), transcripts land under `$CODEX_HOME/sessions/…`, NOT
  `~/.codex/sessions/…` — a watchdog on the wrong home fires a false STALL on a healthy
  run (observed 2026-08-25, PR-2 r1). The script below is SINGLE-SEAT: it stats one
  transcript in one home — for parallel seats, one watchdog per seat with that seat's
  `CODEX_HOME` (a summed `du -sk` variant false-alarmed in practice, PR-2; see the ONE
  liveness policy above).

  ```bash
  V=<verdict-file-path>
  sleep 20
  T=$(ls -t "${CODEX_HOME:-$HOME/.codex}"/sessions/$(date +%Y/%m/%d)/rollout-*.jsonl | head -1)
  LAST=$(stat -f %z "$T" 2>/dev/null || echo 0); QUIET=0
  while true; do
    sleep 30
    [ -s "$V" ] && exit 0
    CUR=$(stat -f %z "$T" 2>/dev/null || echo 0)
    if [ "$CUR" -gt "$LAST" ]; then LAST=$CUR; QUIET=0; else QUIET=$((QUIET+30)); fi
    [ "$QUIET" -ge 180 ] && { echo "STALL: codex transcript frozen ${QUIET}s — kill + retry"; exit 1; }
  done
  ```

- **Run from inside the repo** (observed 2026-09-06): with an isolated `CODEX_HOME` the CLI
  has no trust list, and from a directory outside a git checkout it exits 1 with
  `Not inside a trusted directory and --skip-git-repo-check was not specified` before the
  review starts. `cd` into the repo (or a worktree of it) first; the verdict file may still
  live in the scratchpad.
- **Minimal `CODEX_HOME` isolation is PROVEN (2026-08-05, multiple runs):** a scratch dir
  containing only `auth.json`, exported as `CODEX_HOME`, eliminates the plugin-stack boot hangs
  (two hung runs at 0% CPU for 30 min reproduced them the same night; every minimal-home run
  completed normally, including parallel seats in per-seat homes). Use it by default for
  background/parallel exec runs.
- **Copy the invocation block VERBATIM — never re-type it from memory** (owner directive
  2026-08-05, after a night of re-discovering documented failure modes: an omitted
  `< /dev/null` hung an exec for 14 minutes on stdin; a shared-home parallel launch deadlocked).
  Change only the prompt, model, and output path. If the block needs changing, change it HERE
  first, then use it from here.
- **The review sandbox cannot execute Vitest** (denied its temp SSR directory, `EPERM`) —
  never ask the reviewer to run the suite; present suite results as the author's claim with
  pasted tails, and expect the reviewer to verify via lint/typecheck/AST/probes instead
  (observed consistently across five runs, 2026-07-24).
- Lost output? Session transcripts live under `~/.codex/sessions/<date>/rollout-*.jsonl`
  (last `agent_message`).

## Step 4: Receive it properly

The output is a review, so the AGENTS.md §3 **finding-disposition pass** applies: verify each
finding against the repo before accepting (reviews contain errors — a live 400 once disproved a
reviewer's model-alias claim), classify hard-miss vs judgment-call, flag over-engineering with
an adopt/trim/reject call, and record the fold in a replay table
(workflow.md → Multi-agent review pipeline).

For iterative rounds (contract locks, implementation approvals), follow the pipeline's round
structure — fold, fold-audit, lock-only-on-LOCKABLE — rather than one-shotting.
