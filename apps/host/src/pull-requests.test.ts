import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import type { GhRunner } from "./gh.js";
import { describeGhFailure } from "./gh.js";
import { createPullRequest, linkPullRequest, listIssues, pullRequestStatus, summarizeChecks } from "./pull-requests.js";

// Every test injects its own `gh`: the real one would reach GitHub under
// the developer's login, and the suite must never do that.

const identity = { GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" };

function git(cwd: string, ...args: string[]): string {
  return execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8", env: { ...process.env, ...identity } });
}

// A repo on branch feat/x, two commits over main, with a bare remote that
// has main but not the branch.
function branched(): string {
  const parent = realpathSync(mkdtempSync(path.join(tmpdir(), "tavi-pr-")));
  const dir = path.join(parent, "repo");
  git(parent, "init", "-q", "-b", "main", "repo");
  git(dir, "config", "user.name", "t");
  git(dir, "config", "user.email", "t@t");
  writeFileSync(path.join(dir, "a.txt"), "one\n");
  git(dir, "add", ".");
  git(dir, "commit", "-q", "-m", "init");
  git(parent, "init", "-q", "--bare", "remote.git");
  git(dir, "remote", "add", "origin", path.join(parent, "remote.git"));
  git(dir, "push", "-q", "origin", "main");
  git(dir, "checkout", "-q", "-b", "feat/x");
  git(dir, "config", "--local", "branch.feat/x.base", "main");
  writeFileSync(path.join(dir, "b.txt"), "b\n");
  git(dir, "add", "b.txt");
  git(dir, "commit", "-q", "-m", "feat: add b");
  writeFileSync(path.join(dir, "c.txt"), "c\n");
  git(dir, "add", "c.txt");
  git(dir, "commit", "-q", "-m", "feat: add c");
  return dir;
}

const pr12 = {
  number: 12,
  url: "https://github.com/o/r/pull/12",
  title: "feat: add b and c",
  state: "OPEN",
  isDraft: false,
  baseRefName: "main",
  statusCheckRollup: [{ __typename: "CheckRun", status: "COMPLETED", conclusion: "SUCCESS" }],
  reviewDecision: "",
  additions: 2,
  deletions: 0,
  changedFiles: 2,
  isCrossRepository: false,
  headRefName: "feat/x",
};

function fakeGh(handler: (args: string[]) => unknown): { gh: GhRunner; calls: string[][] } {
  const calls: string[][] = [];
  const gh: GhRunner = async (_cwd, args) => {
    calls.push(args);
    const answer = handler(args);
    if (answer instanceof Error) throw answer;
    return { stdout: typeof answer === "string" ? answer : JSON.stringify(answer) };
  };
  return { gh, calls };
}

function ghError(stderr: string, code?: string): Error {
  const error = new Error(stderr) as Error & { stderr: string; code?: string };
  error.stderr = stderr;
  if (code) error.code = code;
  return error;
}

test("status: no pull request yet, the unpushed count, and the remote; a fork's same-named branch is not ours", async () => {
  const dir = branched();
  const { gh } = fakeGh((args) => (args[1] === "list" ? [{ ...pr12, isCrossRepository: true }] : []));
  const result = await pullRequestStatus(dir, { gh });
  assert.ok(result.ok);
  assert.equal(result.status.branch, "feat/x");
  assert.equal(result.status.pullRequest, null);
  assert.equal(result.status.unpushed, 2);
  assert.equal(result.status.remote, "origin");
  assert.deepEqual(result.status.gh, { ok: true });
});

test("status: gh missing or logged out is a sentence beside an empty answer", async () => {
  const dir = branched();
  const missing = await pullRequestStatus(dir, { gh: fakeGh(() => ghError("", "ENOENT")).gh });
  assert.ok(missing.ok);
  assert.equal(missing.status.gh.ok, false);
  if (!missing.status.gh.ok) assert.match(missing.status.gh.reason, /not installed/);

  const loggedOut = await pullRequestStatus(dir, {
    gh: fakeGh(() => ghError("To get started with GitHub CLI, please run:  gh auth login")).gh,
  });
  assert.ok(loggedOut.ok);
  if (!loggedOut.status.gh.ok) assert.match(loggedOut.status.gh.reason, /not logged in/);
});

test("create pushes the branch first, then opens the pull request against the base and reads it back", async () => {
  const dir = branched();
  let created = false;
  const { gh, calls } = fakeGh((args) => {
    if (args[1] === "list") return created ? [pr12] : [];
    if (args[1] === "create") {
      created = true;
      return "https://github.com/o/r/pull/12\n";
    }
    if (args[1] === "view") return pr12;
    return [];
  });
  const result = await createPullRequest(dir, { title: "feat: add b and c", body: "Two files." }, { gh });
  assert.ok(result.ok, JSON.stringify(result));
  assert.equal(result.pushed, 2);
  assert.equal(result.pullRequest.number, 12);
  assert.equal(result.pullRequest.checks, "passing");
  assert.equal(git(dir, "rev-parse", "--abbrev-ref", "feat/x@{upstream}").trim(), "origin/feat/x");
  const create = calls.find((call) => call[1] === "create");
  assert.deepEqual(create, [
    "pr",
    "create",
    "--head",
    "feat/x",
    "--base",
    "main",
    "--title",
    "feat: add b and c",
    "--body",
    "Two files.",
  ]);

  const again = await createPullRequest(dir, {}, { gh });
  assert.equal(again.ok, false);
  if (!again.ok) {
    assert.equal(again.status, 409);
    assert.match(again.error, /already has pull request #12/);
  }
});

test("create with no title lets gh fill it, and says when gh is not signed in", async () => {
  const dir = branched();
  const { gh, calls } = fakeGh((args) =>
    args[1] === "create" ? "https://github.com/o/r/pull/13\n" : args[1] === "view" ? { ...pr12, number: 13 } : [],
  );
  const result = await createPullRequest(dir, { draft: true }, { gh });
  assert.ok(result.ok, JSON.stringify(result));
  assert.deepEqual(
    calls.find((call) => call[1] === "create"),
    ["pr", "create", "--head", "feat/x", "--base", "main", "--fill", "--draft"],
  );

  const other = branched();
  const refused = await createPullRequest(
    other,
    {},
    { gh: fakeGh((args) => (args[1] === "create" ? ghError("gh auth login required") : [])).gh },
  );
  assert.equal(refused.ok, false);
  if (!refused.ok) {
    assert.equal(refused.status, 503);
    assert.match(refused.error, /not logged in/);
  }
});

test("link remembers a pull request in the branch's config after gh confirms it, and refuses nonsense", async () => {
  const dir = branched();
  const { gh } = fakeGh((args) => {
    if (args[1] === "view" && args[2] === "12") return pr12;
    if (args[1] === "view") return ghError("GraphQL: Could not resolve to a PullRequest with the number of 99.");
    return [];
  });
  const bad = await linkPullRequest(dir, { url: "not a link" }, { gh });
  assert.equal(bad.ok, false);
  if (!bad.ok) assert.equal(bad.status, 400);

  const missing = await linkPullRequest(dir, { number: 99 }, { gh });
  assert.equal(missing.ok, false);
  if (!missing.ok) assert.equal(missing.status, 404);

  const linked = await linkPullRequest(dir, { url: "https://github.com/o/r/pull/12" }, { gh });
  assert.ok(linked.ok, JSON.stringify(linked));
  assert.equal(git(dir, "config", "--get", "branch.feat/x.tavi-pull-request").trim(), "12");

  // From now on status reads the linked one, even though `pr list` finds nothing.
  const status = await pullRequestStatus(dir, { gh });
  assert.ok(status.ok);
  assert.equal(status.status.pullRequest?.number, 12);
});

test("issues come back newest first with gh's trouble beside them", async () => {
  const dir = branched();
  const listed = await listIssues(dir, {
    gh: fakeGh(() => [
      { number: 7, title: "Login redirect loops" },
      { number: 3, title: "Typo" },
    ]).gh,
  });
  assert.deepEqual(listed.issues, [
    { number: 7, title: "Login redirect loops" },
    { number: 3, title: "Typo" },
  ]);
  const broken = await listIssues(dir, { gh: fakeGh(() => ghError("", "ENOENT")).gh });
  assert.deepEqual(broken.issues, []);
  assert.equal(broken.gh.ok, false);
});

test("checks roll up to one word, and gh failures to one sentence", () => {
  assert.equal(summarizeChecks([]), "none");
  assert.equal(summarizeChecks([{ status: "COMPLETED", conclusion: "SUCCESS" }, { state: "SUCCESS" }]), "passing");
  assert.equal(summarizeChecks([{ status: "IN_PROGRESS", conclusion: "" }, { state: "SUCCESS" }]), "pending");
  assert.equal(summarizeChecks([{ status: "IN_PROGRESS" }, { status: "COMPLETED", conclusion: "FAILURE" }]), "failing");
  assert.match(describeGhFailure(ghError("no git remotes found")), /no GitHub remote/);
  assert.match(describeGhFailure(ghError("something odd happened")), /gh said: something odd/);
});

test('unpushed says why it is unknown rather than reading as "everything is on the remote" (#98)', async () => {
  const parent = realpathSync(mkdtempSync(path.join(tmpdir(), "tavi-pr-ab-")));
  const dir = path.join(parent, "repo");
  git(parent, "init", "-q", "-b", "work", "repo");
  git(dir, "config", "user.name", "t");
  git(dir, "config", "user.email", "t@t");
  writeFileSync(path.join(dir, "a.txt"), "one\n");
  git(dir, "add", ".");
  git(dir, "commit", "-q", "-m", "init");
  // No upstream and a default branch (`main`, per origin/HEAD) with no ref
  // that resolves, so `rev-list work...main` fails.
  git(dir, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main");

  const result = await pullRequestStatus(dir, { gh: async () => ({ stdout: "[]" }) });
  assert.ok(result.ok, JSON.stringify(result));
  // The zero a 0.1.17 phone decodes is still there, beside the reason.
  assert.equal(result.status.unpushed, 0);
  assert.match(result.status.unpushedFailed ?? "", /main/);
});
