import { describeGitError, git } from "./git-exec.js";
import { describeGhFailure, runGh, type GhRunner } from "./gh.js";
import { type AheadBehind, aheadBehind, baseBranch, currentBranch, pushRemote, upstreamInfo } from "./git-refs.js";
import { pushBranch } from "./commits.js";

// Source Control — Pull request (#79, #73 part 5; PRD §7.12): one
// worktree's pull request, created and read through the person's own `gh`
// login on that computer. Tavi holds no GitHub token: when gh is missing or
// logged out the answer is a sentence, never a prompt.

export interface PullRequestInfo {
  number: number;
  url: string;
  title: string;
  state: "open" | "closed" | "merged";
  isDraft: boolean;
  base: string;
  checks: "passing" | "failing" | "pending" | "none";
  review: "approved" | "changes-requested" | "review-required" | null;
  additions: number;
  deletions: number;
  changedFiles: number;
}

export type GhState = { ok: true } | { ok: false; reason: string };

export interface PullRequestStatus {
  path: string;
  branch: string | null;
  pullRequest: PullRequestInfo | null;
  // Commits a pull request would push first: what the upstream lacks, or
  // on a never-pushed branch everything over its base.
  unpushed: number;
  // Why that count could not be measured, as a sentence (#98). Absent when
  // it was: a git failure must not read as "everything is on the remote".
  unpushedFailed?: string;
  remote: string | null;
  gh: GhState;
}

export interface PullRequestDeps {
  gh?: GhRunner;
}

export type PullRequestStatusResult =
  | { ok: true; status: PullRequestStatus }
  | { ok: false; status: 503; error: string };

const PR_FIELDS =
  "number,url,title,state,isDraft,baseRefName,statusCheckRollup,reviewDecision,additions,deletions,changedFiles,isCrossRepository,headRefName";
const LINK_KEY_PREFIX = "branch.";
const LINK_KEY_SUFFIX = ".tavi-pull-request";

export async function pullRequestStatus(
  worktreePath: string,
  deps: PullRequestDeps = {},
): Promise<PullRequestStatusResult> {
  const gh = deps.gh ?? runGh;
  let branch: string | null;
  try {
    branch = await currentBranch(worktreePath);
  } catch (error) {
    return { ok: false, status: 503, error: `git could not read that worktree: ${describeGitError(error)}` };
  }
  const remote = branch ? await pushRemote(worktreePath, branch) : null;
  // The zero stays beside the reason so a phone built against 0.1.17, which
  // decodes `unpushed` as a required number, keeps working.
  const counted = branch ? await unpushedCount(worktreePath, branch) : null;
  const unpushed = counted?.ok ? counted.ahead : 0;
  const unpushedFailed = !counted || counted.ok ? {} : { unpushedFailed: counted.error };
  // A detached HEAD has no branch to look a pull request up by; gh is not
  // asked, and not asking is not a gh failure.
  const found = branch ? await findPullRequest(worktreePath, branch, gh) : ({ ok: true, pullRequest: null } as const);
  return {
    ok: true,
    status: {
      path: worktreePath,
      branch,
      pullRequest: found.ok ? found.pullRequest : null,
      unpushed,
      ...unpushedFailed,
      remote,
      gh: found.ok ? { ok: true } : { ok: false, reason: found.reason },
    },
  };
}

export interface CreatePullRequestOptions {
  title?: string | undefined;
  body?: string | undefined;
  draft?: boolean | undefined;
}

export type CreatePullRequestResult =
  | { ok: true; pullRequest: PullRequestInfo; pushed: number }
  // `created` marks the one failure that still changed GitHub: gh opened the
  // pull request and only the read-back failed, so the caller must forget its
  // "no pull request" badge (#103).
  | { ok: false; status: 409 | 503; error: string; created?: true };

const MAX_TITLE = 256;
const MAX_BODY = 60_000;

// Pushes what the remote lacks, then `gh pr create` against the branch's
// base. An existing pull request is a 409 that names it.
export async function createPullRequest(
  worktreePath: string,
  options: CreatePullRequestOptions,
  deps: PullRequestDeps = {},
): Promise<CreatePullRequestResult> {
  const gh = deps.gh ?? runGh;
  let branch: string | null;
  try {
    branch = await currentBranch(worktreePath);
  } catch (error) {
    return { ok: false, status: 503, error: `git could not read that worktree: ${describeGitError(error)}` };
  }
  if (!branch)
    return {
      ok: false,
      status: 409,
      error: "This worktree is not on a branch, so there is nothing to open a pull request for.",
    };
  const title = (options.title ?? "").trim();
  const body = options.body ?? "";
  if (title.length > MAX_TITLE || body.length > MAX_BODY || title.includes("\0") || body.includes("\0")) {
    return { ok: false, status: 409, error: "That title or description is too long." };
  }
  const existing = await findPullRequest(worktreePath, branch, gh);
  if (!existing.ok) return { ok: false, status: 503, error: existing.reason };
  if (existing.pullRequest && existing.pullRequest.state === "open") {
    return { ok: false, status: 409, error: `${branch} already has pull request #${existing.pullRequest.number}.` };
  }

  let pushed = 0;
  const upstream = await upstreamInfo(worktreePath, branch);
  if (!upstream || upstream.ahead > 0) {
    const push = await pushBranch(worktreePath);
    if (!push.ok) return { ok: false, status: push.status, error: push.error };
    pushed = push.pushed;
  }

  const base = await baseBranch(worktreePath, branch);
  const args = ["pr", "create", "--head", branch];
  if (base && base !== branch) args.push("--base", base);
  if (title) args.push("--title", title, "--body", body);
  else args.push("--fill");
  if (options.draft) args.push("--draft");
  let url: string;
  try {
    const { stdout } = await gh(worktreePath, args);
    url =
      stdout
        .trim()
        .split("\n")
        .filter((line) => /^https?:\/\//.test(line))
        .pop() ?? "";
  } catch (error) {
    const text = String((error as { stderr?: string }).stderr ?? "");
    if (/already exists/i.test(text)) {
      const again = await findPullRequest(worktreePath, branch, gh);
      const number = again.ok && again.pullRequest ? `#${again.pullRequest.number}` : "one";
      return { ok: false, status: 409, error: `${branch} already has pull request ${number}.` };
    }
    return { ok: false, status: 503, error: describeGhFailure(error) };
  }
  const number = numberFromUrl(url);
  const created = number ? await viewPullRequest(worktreePath, number, gh) : null;
  if (!created?.ok || !created.pullRequest) {
    // gh made it but the read-back failed. A pull request numbered 0 with no
    // base is not a pull request; the person is told it exists, where, and
    // why this host cannot show it yet (#103).
    const reason = created && !created.ok ? created.reason : "gh did not describe it.";
    return {
      ok: false,
      status: 503,
      error: `The pull request was created${url ? ` (${url})` : ""}, but reading it back failed: ${reason}`,
      created: true,
    };
  }
  return { ok: true, pushed, pullRequest: created.pullRequest };
}

export type LinkPullRequestResult =
  | { ok: true; pullRequest: PullRequestInfo }
  | { ok: false; status: 400 | 404 | 409 | 503; error: string };

// Remembers a pull request for the branch in the repository's own config
// (`branch.<b>.tavi-pull-request`) after gh confirms it exists here.
export async function linkPullRequest(
  worktreePath: string,
  reference: { number?: unknown; url?: unknown },
  deps: PullRequestDeps = {},
): Promise<LinkPullRequestResult> {
  const gh = deps.gh ?? runGh;
  const number =
    typeof reference.number === "number" && Number.isInteger(reference.number) && reference.number > 0
      ? reference.number
      : typeof reference.url === "string"
        ? (numberFromUrl(reference.url) ?? numberFromText(reference.url))
        : null;
  if (!number) return { ok: false, status: 400, error: "Give a pull request number or its GitHub link." };
  let branch: string | null;
  try {
    branch = await currentBranch(worktreePath);
  } catch (error) {
    return { ok: false, status: 503, error: `git could not read that worktree: ${describeGitError(error)}` };
  }
  if (!branch) return { ok: false, status: 409, error: "This worktree is not on a branch." };
  const viewed = await viewPullRequest(worktreePath, number, gh);
  if (!viewed.ok) return { ok: false, status: 503, error: viewed.reason };
  if (!viewed.pullRequest)
    return { ok: false, status: 404, error: `There is no pull request #${number} on this repository.` };
  try {
    await git(worktreePath, ["config", "--local", `${LINK_KEY_PREFIX}${branch}${LINK_KEY_SUFFIX}`, String(number)]);
  } catch (error) {
    return { ok: false, status: 503, error: `git could not remember the link: ${describeGitError(error)}` };
  }
  return { ok: true, pullRequest: viewed.pullRequest };
}

export interface IssueSummary {
  number: number;
  title: string;
}

export type IssuesResult = { ok: true; issues: IssueSummary[]; gh: GhState };

const MAX_ISSUES = 30;

// Open issues, newest first, for naming a branch (#79; the create sheet's
// "From a GitHub issue"). gh trouble is reported beside an empty list.
export async function listIssues(repositoryPath: string, deps: PullRequestDeps = {}): Promise<IssuesResult> {
  const gh = deps.gh ?? runGh;
  try {
    const { stdout } = await gh(repositoryPath, [
      "issue",
      "list",
      "--state",
      "open",
      "--limit",
      String(MAX_ISSUES),
      "--json",
      "number,title",
    ]);
    const parsed: unknown = JSON.parse(stdout);
    const issues: IssueSummary[] = [];
    if (Array.isArray(parsed)) {
      for (const item of parsed as { number?: unknown; title?: unknown }[]) {
        if (typeof item.number === "number" && typeof item.title === "string")
          issues.push({ number: item.number, title: item.title.slice(0, 200) });
      }
    }
    return { ok: true, issues, gh: { ok: true } };
  } catch (error) {
    return { ok: true, issues: [], gh: { ok: false, reason: describeGhFailure(error) } };
  }
}

// MARK: gh answers

type Found = { ok: true; pullRequest: PullRequestInfo | null } | { ok: false; reason: string };

// The linked one when the branch has a link, else the open pull request
// whose head is this branch in this repository (a fork's same-named branch
// is not ours — the rule /api/repos follows).
async function findPullRequest(worktreePath: string, branch: string, gh: GhRunner): Promise<Found> {
  const linked = await linkedNumber(worktreePath, branch);
  if (linked) {
    const viewed = await viewPullRequest(worktreePath, linked, gh);
    if (!viewed.ok || viewed.pullRequest) return viewed;
    // The link points at nothing any more: fall through to the search.
  }
  try {
    const { stdout } = await gh(worktreePath, [
      "pr",
      "list",
      "--head",
      branch,
      "--state",
      "open",
      "--json",
      PR_FIELDS,
      "--limit",
      "5",
    ]);
    const parsed: unknown = JSON.parse(stdout);
    if (!Array.isArray(parsed)) return { ok: true, pullRequest: null };
    for (const item of parsed as Record<string, unknown>[]) {
      if (item.isCrossRepository === false) {
        const info = parsePullRequest(item);
        if (info) return { ok: true, pullRequest: info };
      }
    }
    return { ok: true, pullRequest: null };
  } catch (error) {
    return { ok: false, reason: describeGhFailure(error) };
  }
}

async function viewPullRequest(worktreePath: string, number: number, gh: GhRunner): Promise<Found> {
  try {
    const { stdout } = await gh(worktreePath, ["pr", "view", String(number), "--json", PR_FIELDS]);
    const parsed: unknown = JSON.parse(stdout);
    const info =
      typeof parsed === "object" && parsed !== null ? parsePullRequest(parsed as Record<string, unknown>) : null;
    return { ok: true, pullRequest: info };
  } catch (error) {
    const text = String((error as { stderr?: string }).stderr ?? "");
    if (/Could not resolve to a PullRequest|no pull requests found|not found/i.test(text))
      return { ok: true, pullRequest: null };
    return { ok: false, reason: describeGhFailure(error) };
  }
}

function parsePullRequest(item: Record<string, unknown>): PullRequestInfo | null {
  if (typeof item.number !== "number" || typeof item.url !== "string") return null;
  const rawState = String(item.state ?? "OPEN").toUpperCase();
  const state: PullRequestInfo["state"] = rawState === "MERGED" ? "merged" : rawState === "CLOSED" ? "closed" : "open";
  const decision = String(item.reviewDecision ?? "").toUpperCase();
  const review: PullRequestInfo["review"] =
    decision === "APPROVED"
      ? "approved"
      : decision === "CHANGES_REQUESTED"
        ? "changes-requested"
        : decision === "REVIEW_REQUIRED"
          ? "review-required"
          : null;
  return {
    number: item.number,
    url: item.url,
    title: typeof item.title === "string" ? item.title : "",
    state,
    isDraft: item.isDraft === true,
    base: typeof item.baseRefName === "string" ? item.baseRefName : "",
    checks: summarizeChecks(item.statusCheckRollup),
    review,
    additions: typeof item.additions === "number" ? item.additions : 0,
    deletions: typeof item.deletions === "number" ? item.deletions : 0,
    changedFiles: typeof item.changedFiles === "number" ? item.changedFiles : 0,
  };
}

// One word for the whole rollup: a check run carries status/conclusion, a
// commit status carries state; any failure wins, then anything unfinished.
export function summarizeChecks(rollup: unknown): PullRequestInfo["checks"] {
  if (!Array.isArray(rollup) || rollup.length === 0) return "none";
  let pending = false;
  for (const entry of rollup as Record<string, unknown>[]) {
    const conclusion = String(entry.conclusion ?? "").toUpperCase();
    const status = String(entry.status ?? "").toUpperCase();
    const state = String(entry.state ?? "").toUpperCase();
    if (
      ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"].includes(conclusion) ||
      ["FAILURE", "ERROR"].includes(state)
    )
      return "failing";
    if ((status && status !== "COMPLETED") || state === "PENDING" || state === "EXPECTED") pending = true;
  }
  return pending ? "pending" : "passing";
}

async function linkedNumber(worktreePath: string, branch: string): Promise<number | null> {
  try {
    const value = (
      await git(worktreePath, ["config", "--get", `${LINK_KEY_PREFIX}${branch}${LINK_KEY_SUFFIX}`])
    ).stdout.trim();
    const number = Number.parseInt(value, 10);
    return Number.isInteger(number) && number > 0 ? number : null;
  } catch {
    // No `branch.<b>.tavi-pull-request` set (the ordinary case): the
    // caller falls back to asking gh which PR has this head.
    return null;
  }
}

// What a pull request would push first, or why git could not say — never a
// silent 0, which reads as "everything is already on the remote" (#98).
async function unpushedCount(worktreePath: string, branch: string): Promise<AheadBehind> {
  const upstream = await upstreamInfo(worktreePath, branch);
  if (upstream) return { ok: true, ahead: upstream.ahead, behind: upstream.behind };
  return aheadBehind(worktreePath, branch, await baseBranch(worktreePath, branch));
}

function numberFromUrl(text: string): number | null {
  const match = text.match(/\/pull\/(\d+)/);
  return match ? Number.parseInt(match[1] ?? "", 10) || null : null;
}

function numberFromText(text: string): number | null {
  const match = text.trim().match(/^#?(\d+)$/);
  return match ? Number.parseInt(match[1] ?? "", 10) || null : null;
}
