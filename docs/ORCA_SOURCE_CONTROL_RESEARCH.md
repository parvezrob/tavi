# Orca's git and worktree model — source-level read (2026-09-02)

The bar for Tavi's source control is Orca's mobile app, matched then beaten (owner, 2026-09-02; `ROADMAP.md`). This is what Orca actually does, read from `stablyai/orca` (MIT, `git clone --depth 1` on 2026-09-02; refs are repo-relative `path:line` and will drift). Verified in code unless marked *inferred*. Mobile is in-tree (`mobile/`, Expo/React Native) and near desktop parity on git — a higher bar than the docs page suggests.

## Data model

- Worktree is a first-class entity, not owned by a task or session: `Worktree = GitWorktreeInfo & {…}` (`src/shared/worktree/types.ts:22-38,61-144`), id `${repoId}::${path}` (`src/shared/worktree/id.ts:21-23`). Git is the source of truth for existence/branch/HEAD; Orca persists only a metadata overlay (`worktreeMeta`, `src/shared/persisted-state-types.ts:50-112`) merged with a live `git worktree list` at read time.
- Repo → worktree 1:N; worktree → agent 1:N (`src/shared/agent-session-record.ts:25-31`). Creation is explicit, never one-per-task.
- Path: `~/orca/workspaces/<repoName>/<sanitizedName>` (`src/main/ipc/worktree-logic.ts:97-124`, `src/shared/constants.ts:157-161`). Base ref: `origin/HEAD` → `origin/main` → `origin/master` → `main` → `master` (`src/main/git/repo-default-base-ref.ts:21-26,64-75`), overridable.
- Lineage = parent→child between worktrees (`src/shared/worktree/lineage-types.ts:19-45`); powers "Child" / "N children" on mobile rows.

## Lifecycle

- Create: `git worktree add --no-track -b <branch> <path> [<base>]` (`src/main/git/worktree-add.ts:193-204`); `--no-track` so status never says "behind N" before publish, compensated by `push.autoSetupRemote true` and `branch.<b>.base <base>` (`:63-117`). Then `.worktreeinclude` copies ignored files such as `.env` (`src/main/git/worktree-include-file.ts:80-146`) and an optional setup command runs.
- Remove: rename the checkout to a sibling trash dir, `git worktree remove --force` for deregistration only (prune fallback), recursive delete in the background (`src/main/git/worktree-removal.ts:114-183`). Non-force removes preflight `status --porcelain --untracked-files=all` and refuse on dirt (`worktree-removal-preflight.ts:8-44`); path safety refuses repo root/home/parents (`worktree-removal-safety.ts:65-152`). Branch delete is `-d`, escalating only after proving squash-merge equivalence (`merge-tree --write-tree` / `cherry -v` / `patch-id`) via a CAS `update-ref -d` (`worktree-branch-removal.ts:107-182`); unprovable branches are kept and surfaced.
- Reconcile: full `worktree list --porcelain` rescan at most every 5 min, gated by an admin-dir fingerprint (`docs/reference/worktree-scan-fingerprint.md`).

## Feature surface, and what mobile gets

Mobile speaks WebSocket JSON-RPC over `lan | tailscale | relay` (`mobile/src/transport/stable-logical-rpc-client.ts:11`), QR-paired, versioned with a hard-block screen. An allowlist (`src/main/runtime/runtime-rpc/runtime-rpc-mobile-method-allowlist.ts`, 265 entries) gates it; the only git/worktree RPCs mobile lacks are `git.bulkDiscard`, `git.checkIgnored`, `git.conflictOperation`, remote-URL helpers, `git.submoduleStatus`, and the raw `worktree.list`/`lineageList` variants.

So mobile has: stage/unstage/discard (file level only — no hunks), commit, AI commit message (`git.generateCommitMessage`, cancellable), push/pull/fetch/sync/publish/fast-forward/rebase-from-base, branch switch, commit log, branch-vs-base compare, abort merge/rebase, create PR/MR, merge PR, PR checks, inline review comments, worktree create/remove. Action sheet with per-action disable hints: `mobile/src/source-control/mobile-source-control-actions.ts:84-225`.

PR creation shells out to **`gh pr create`** (`src/main/github/client/create/create-github-pull-request.ts:83-109`) / `glab mr create`; auth is the user's existing CLI login. No OAuth, no PAT.

### Screens

- Home = list of paired hosts (`mobile/src/home/MobileHomeHostList.tsx`), each card only `N worktrees · M active`. Drill into a host → worktree list groupable by none / repo / status / PR status (`mobile/src/worktree/workspace-list-sections.ts:147-235`). Per worktree: session, source-control (tabs `changes | pr | history`), review, files, agent-history.
- **The list row is git-blind.** `WorktreeListRow.tsx:113-196` shows name, PR badge `#123`, repo, branch, agent sub-rows (dot, logo, last assistant message, time), lineage, terminal count — no dirty count, no ahead/behind, no +/−. Structural: the row's payload `RuntimeWorktreePsSummary` (`src/shared/runtime-worktree-contracts.ts:29-69`) has no git-status fields beyond `branch` and `linkedPR`. Those appear only on Source Control's branch card: `N changed / N staged / N on branch`, `ahead, behind` (`MobileSourceControlBranchCard.tsx:52-58`).

## Status refresh

Desktop: fs-event driven (`@parcel/watcher`) with 125 ms debounce, 3 s minimum gap, 60 s idle backstop, 5-min backoff (`useGitStatusPolling.ts:26-37`). One batched `git -c core.quotePath=false status --porcelain=v2 --branch --untracked-files=all`, streamed, capped at 1000 entries (`status-read.ts:122-133`); `rev-list --left-right --count` only when porcelain's ahead/behind can't be trusted, with a 5-min negative cache for "no upstream".

Mobile: the worktree list polls `worktree.ps` every 3 s while foregrounded plus a `worktreesChanged` event (`mobile/src/worktree/host-worktree-refresh.ts:37-79`). **Source Control has no poller** — load on mount, manual refresh, after actions (`use-mobile-source-control-loaders.ts:273-275`).

## "Fan out and merge the winner"

Not a feature. The README line has no code behind it: compare is single-worktree-vs-base, merge-tree is PR conflict preview, the create UI takes one agent. There is no local "merge worktree into main"; integration is always through PR merge. The real workflow is manual: N worktrees off one base, eyeball each diff, ship one via PR, multi-select-delete the rest.

## Clever

- Agent Map (desktop): circle packing, agents by golden-angle spiral inside their worktree circle, worktrees inside repo circles, lineage as chevrons (`agent-map-agent-placement.ts`).
- HEAD read from `.git` metadata files without spawning git (`src/shared/worktree/types.ts:40-49`).
- Patch-id squash-merge detection before deleting a branch.
- "Resolve Conflicts With AI": builds a prompt from unresolved entries and hands it to an agent (`dialog-layer.tsx:187`, `ai/use-ai.ts:150-158`).

## Where Tavi beats it

1. The mobile list row is git-blind; ours already reads `fix/foo · +3/−1 · 2 uncommitted` and Orca's wire format has no slot for it.
2. Orca's mobile home is a host list; ours lands on the work.
3. No live status on mobile Source Control; ours can push updates.
4. Mobile delete is `force: true` behind a bare confirm with no dirty/unpushed warning (`use-host-worktree-actions.ts:126-129`); ours names what would be lost and offers "push, then remove" first.
5. No hunk staging, amend, stash, or cherry-pick anywhere (`staging.ts:18,36`).
6. No cross-worktree compare, despite the marketing.
7. `gh`/`glab` CLI dependency: PR creation silently unavailable without the CLI installed and logged in — we should say so up front, or do the same and say so.

## What to copy

`--no-track` + `push.autoSetupRemote` + `branch.<b>.base` on create; `.worktreeinclude` (or our own rule) for `.env`; the rename-then-deregister remove; refuse-on-dirt preflight; the base-ref resolution order; one batched `status --porcelain=v2 --branch` per refresh with an entry cap; PR via the user's `gh` login.
