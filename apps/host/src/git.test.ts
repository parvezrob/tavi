import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, realpathSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { invalidateRepos, listRepos, listReposCached, parseWorktreeList, type ListReposOptions, type RepoInfo } from "./git.js";

// Tests never shell out to the developer's real `gh`.
const noPullRequests = { pullRequests: async () => null };

function git(cwd: string, ...args: string[]): string {
  return execFileSync("git", ["-C", cwd, ...args], {
    encoding: "utf8",
    env: { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" },
  });
}

// realpath'd: macOS's /tmp → /private/tmp (and /var → /private/var) would
// otherwise make every path git itself prints look foreign (the #57 trap).
function mktemp(): string {
  return realpathSync(mkdtempSync(path.join(tmpdir(), "tavi-git-")));
}

// Each repo lives under its own fresh parent directory, never directly
// under the shared system tmpdir — `listRepos` scans one level under a
// root, and the system tmpdir can hold unrelated entries from other tests
// running at the same time.
function repo(): { dir: string; parent: string } {
  const parent = mktemp();
  const dir = path.join(parent, "repo");
  git(parent, "init", "-q", "-b", "main", "repo");
  writeFileSync(path.join(dir, "README.md"), "hello\n");
  git(dir, "add", ".");
  git(dir, "commit", "-q", "-m", "init");
  return { dir, parent };
}

async function repos(roots: string[], options: ListReposOptions = noPullRequests): Promise<RepoInfo[]> {
  return (await listRepos(roots, options)).repos;
}

test("parseWorktreeList reads main, linked, and detached records", () => {
  const raw = [
    "worktree /repo",
    "HEAD aaaaaaa",
    "branch refs/heads/main",
    "",
    "worktree /repo-fix",
    "HEAD bbbbbbb",
    "branch refs/heads/fix/foo",
    "",
    "worktree /repo-detached",
    "HEAD ccccccc",
    "detached",
    "",
  ].join("\n");

  const worktrees = parseWorktreeList(raw);
  assert.equal(worktrees.length, 3);
  assert.deepEqual(
    worktrees.map((w) => [w.path, w.branch, w.isMain]),
    [
      ["/repo", "main", true],
      ["/repo-fix", "fix/foo", false],
      ["/repo-detached", null, false],
    ],
  );
});

test("parseWorktreeList reads locked and prunable flags", () => {
  const raw = ["worktree /repo", "HEAD aaaaaaa", "branch refs/heads/main", "locked stale", "prunable gone", ""].join("\n");
  const [worktree] = parseWorktreeList(raw);
  assert.equal(worktree?.locked, true);
  assert.equal(worktree?.prunable, true);
});

test("parseWorktreeList reads the -z form, keeps a newline inside a path, and does not crown a bare record's neighbour (#72)", () => {
  const raw = ["worktree /repo\0HEAD aaaaaaa\0branch refs/heads/main\0", "worktree /odd\nname\0HEAD bbbbbbb\0detached\0"].join("\0");
  const worktrees = parseWorktreeList(raw);
  assert.deepEqual(
    worktrees.map((w) => [w.path, w.branch, w.isMain]),
    [
      ["/repo", "main", true],
      ["/odd\nname", null, false],
    ],
  );
  // A bare repository's first record is the repository itself: skipped,
  // and the linked checkout after it is not "main".
  const bare = ["worktree /repo.git\0HEAD aaaaaaa\0bare\0", "worktree /repo-fix\0HEAD bbbbbbb\0branch refs/heads/fix\0"].join("\0");
  assert.deepEqual(parseWorktreeList(bare).map((w) => [w.path, w.isMain]), [["/repo-fix", false]]);
});

test("listRepos reports the main worktree, a linked worktree, dirty count, ahead/behind, and whether each is inside the roots", async () => {
  const { dir, parent } = repo();
  const worktreeDir = path.join(parent, "fix-foo");
  git(dir, "worktree", "add", "-b", "fix/foo", worktreeDir, "main");
  writeFileSync(path.join(worktreeDir, "scratch.txt"), "wip\n");
  git(worktreeDir, "add", "scratch.txt");
  // A worktree outside every root: git lists it, the answer says where it is.
  const elsewhere = path.join(mktemp(), "far-away");
  git(dir, "worktree", "add", "-b", "fix/far", elsewhere, "main");

  const answer = await listRepos([parent], noPullRequests);
  assert.equal(answer.truncated, false);
  assert.equal(answer.error, null);
  const found = answer.repos.find((r) => r.root === dir);
  assert.ok(found, "expected the repository to be discovered");
  assert.equal(found?.defaultBranch, "main");
  assert.equal(found?.truncated, false);

  const main = found?.worktrees.find((w) => w.isMain);
  assert.equal(main?.branch, "main");
  assert.equal(main?.dirty, 0);
  assert.equal(main?.withinRoots, true);

  const linked = found?.worktrees.find((w) => w.path === worktreeDir);
  assert.equal(linked?.branch, "fix/foo");
  assert.equal(linked?.dirty, 1);
  assert.equal(linked?.ahead, 0);
  assert.equal(linked?.behind, 0);
  assert.equal(linked?.withinRoots, true);
  assert.equal(found?.worktrees.find((w) => w.path === elsewhere)?.withinRoots, false);
});

test("listRepos computes ahead/behind against the default branch, for a detached worktree too", async () => {
  const { dir, parent } = repo();
  const linkedPath = path.join(parent, "fix-bar");
  git(dir, "worktree", "add", "-b", "fix/bar", linkedPath, "main");
  writeFileSync(path.join(linkedPath, "extra.txt"), "one\n");
  git(linkedPath, "add", "extra.txt");
  git(linkedPath, "commit", "-q", "-m", "extra");

  // A second branch that stays behind: main gains a commit `fix/baz` never
  // sees, asserted as `behind` so a left/right inversion in the rev-list
  // call fails here rather than passing on `ahead` alone.
  const bazPath = path.join(parent, "fix-baz");
  git(dir, "worktree", "add", "-b", "fix/baz", bazPath, "main");
  // A detached worktree standing on fix/bar's commit: compared by its HEAD.
  const detachedPath = path.join(parent, "detached");
  git(dir, "worktree", "add", "--detach", detachedPath, "fix/bar");
  // A tag named like the default branch must not be what "main" resolves to.
  git(dir, "tag", "main-tag", "fix/bar");
  writeFileSync(path.join(dir, "advance.txt"), "advance\n");
  git(dir, "add", "advance.txt");
  git(dir, "commit", "-q", "-m", "advance main");

  const found = (await repos([parent])).find((r) => r.root === dir);
  const linked = found?.worktrees.find((w) => w.path === linkedPath);
  assert.equal(linked?.ahead, 1);
  assert.equal(linked?.behind, 1);

  const baz = found?.worktrees.find((w) => w.path === bazPath);
  assert.equal(baz?.ahead, 0);
  assert.equal(baz?.behind, 1);

  const detached = found?.worktrees.find((w) => w.path === detachedPath);
  assert.equal(detached?.branch, null);
  assert.equal(detached?.ahead, 1);
  assert.equal(detached?.behind, 1);
});

test("listRepos measures against the remote's default branch when there is no local copy (#72)", async () => {
  const { dir, parent } = repo();
  git(dir, "checkout", "-q", "-b", "work");
  git(dir, "update-ref", "refs/remotes/origin/main", "main");
  git(dir, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main");
  git(dir, "branch", "-D", "main");
  writeFileSync(path.join(dir, "w.txt"), "w\n");
  git(dir, "add", "w.txt");
  git(dir, "commit", "-q", "-m", "work");

  const found = (await repos([parent])).find((r) => r.root === dir);
  assert.equal(found?.defaultBranch, "main");
  const main = found?.worktrees.find((w) => w.isMain);
  assert.equal(main?.branch, "work");
  assert.equal(main?.ahead, 1);
  assert.equal(main?.behind, 0);
});

test("listRepos asks the pull-request lookup once per branch and carries its answer (#74)", async () => {
  const { dir, parent } = repo();
  git(dir, "worktree", "add", "-b", "feat/pr", path.join(parent, "feat-pr"), "main");
  const asked: string[] = [];
  const found = (
    await repos([parent], {
      pullRequests: async (repository, branch) => {
        asked.push(branch);
        assert.equal(repository, dir);
        return branch === "feat/pr" ? { number: 48, url: "https://github.com/x/y/pull/48" } : null;
      },
    })
  ).find((r) => r.root === dir);
  // The default branch is never asked about: it has no PR of its own.
  assert.deepEqual(asked, ["feat/pr"]);
  assert.deepEqual(found?.worktrees.find((w) => w.branch === "feat/pr")?.pullRequest, { number: 48, url: "https://github.com/x/y/pull/48" });
  assert.equal(found?.worktrees.find((w) => w.isMain)?.pullRequest, null);
});

test("listRepos asks about pull requests a few at a time and tells the stragglers to stop when the budget runs out (#85)", async () => {
  const { dir, parent } = repo();
  for (let index = 0; index < 6; index += 1) git(dir, "worktree", "add", "-b", `feat/${index}`, path.join(parent, `feat-${index}`), "main");
  let inFlight = 0;
  let mostInFlight = 0;
  let aborted = 0;
  const started = Date.now();
  const found = (
    await repos([parent], {
      pullRequests: (_repository, branch, signal) =>
        new Promise<{ number: number; url: string } | null>((resolve) => {
          inFlight += 1;
          mostInFlight = Math.max(mostInFlight, inFlight);
          if (branch === "feat/0") {
            // Never answers on its own: only the budget ends it.
            signal?.addEventListener("abort", () => {
              aborted += 1;
              inFlight -= 1;
              resolve(null);
            });
            return;
          }
          setTimeout(() => {
            inFlight -= 1;
            resolve({ number: 1, url: "https://github.com/x/y/pull/1" });
          }, 20);
        }),
    })
  ).find((r) => r.root === dir);
  const elapsed = Date.now() - started;
  assert.ok(mostInFlight <= 4, `at most four lookups at once, saw ${mostInFlight}`);
  assert.equal(aborted, 1);
  assert.ok(elapsed >= 2_900 && elapsed < 6_000, `the pass ends with the budget, took ${elapsed} ms`);
  assert.equal(found?.worktrees.find((w) => w.branch === "feat/0")?.pullRequest, null);
  assert.equal(found?.worktrees.filter((w) => w.pullRequest !== null).length, 5);
});

test("listRepos returns no repositories for a plain folder", async () => {
  const dir = mktemp();
  assert.deepEqual(await listRepos([dir], noPullRequests), { repos: [], truncated: false, error: null });
});

test("listRepos says so when git is not installed, instead of listing nothing (#72)", async () => {
  const { parent } = repo();
  const savedPath = process.env.PATH;
  process.env.PATH = mktemp();
  try {
    const answer = await listRepos([parent], noPullRequests);
    assert.deepEqual(answer, { repos: [], truncated: false, error: "git is not installed on this computer." });
  } finally {
    process.env.PATH = savedPath;
  }
});

test("listRepos flags a branch list cut at the cap (#72)", async () => {
  const { dir, parent } = repo();
  const head = git(dir, "rev-parse", "HEAD").trim();
  const refs = Array.from({ length: 205 }, (_, index) => `create refs/heads/stale/${String(index).padStart(3, "0")} ${head}\n`).join("");
  execFileSync("git", ["-C", dir, "update-ref", "--stdin"], { input: refs });
  const found = (await repos([parent])).find((r) => r.root === dir);
  assert.equal(found?.truncated, true);
  assert.equal(found?.branches.length, 201);
  assert.equal(found?.branches[0], "main");
});

test("listRepos finds a local default branch even when nothing has it checked out", async () => {
  const { dir, parent } = repo();
  // Move the main worktree itself off `main` so no worktree anywhere has it
  // checked out — only a ref, the ordinary case for a repo someone is
  // actively working on.
  git(dir, "checkout", "-q", "-b", "work");

  const found = (await repos([parent])).find((r) => r.root === dir);
  assert.equal(found?.defaultBranch, "main");
});

test("listRepos counts a rename as one dirty file, not two", async () => {
  const { dir } = repo();
  renameSync(path.join(dir, "README.md"), path.join(dir, "RENAMED.md"));
  git(dir, "add", "-A");

  const found = (await repos([path.dirname(dir)])).find((r) => r.root === dir);
  const main = found?.worktrees.find((w) => w.isMain);
  assert.equal(main?.dirty, 1);
});

test("listRepos skips an unreadable repository instead of failing the whole list", async () => {
  const parent = mktemp();
  const good = repo();
  git(good.dir, "worktree", "add", "-b", "fix/foo", path.join(good.parent, "fix-foo"), "main");
  const broken = path.join(parent, "broken");
  git(parent, "init", "-q", "-b", "main", "broken");
  writeFileSync(path.join(broken, "a.txt"), "a\n");
  git(broken, "add", ".");
  git(broken, "commit", "-q", "-m", "init");
  // Corrupt the repository so `git worktree list` fails on it specifically.
  rmSync(path.join(broken, ".git", "HEAD"));

  const found = await repos([parent, good.parent]);
  assert.equal(found.some((r) => r.root === broken), false);
  assert.ok(found.some((r) => r.root === good.dir), "the healthy repository is still reported");
});

test("listReposCached serves the last answer at once, refreshes behind it, and forgets it on invalidate", async () => {
  const parent = realpathSync(mkdtempSync(path.join(tmpdir(), "tavi-repos-cache-")));
  const dir = path.join(parent, "app");
  execFileSync("git", ["init", "-q", "-b", "main", dir]);
  writeFileSync(path.join(dir, "a.txt"), "a\n");
  execFileSync("git", ["-C", dir, "add", "."]);
  execFileSync("git", ["-C", dir, "commit", "-q", "-m", "init"], { env: { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" } });
  const noPr = { pullRequests: async () => null };
  invalidateRepos();
  const first = (await listReposCached([parent], noPr)).repos;
  assert.equal(first.find((r) => r.root === dir)?.worktrees[0]?.dirty, 0);
  writeFileSync(path.join(dir, "b.txt"), "b\n");
  // Within the fresh window the cached answer comes back unchanged...
  const cached = (await listReposCached([parent], noPr)).repos;
  assert.equal(cached.find((r) => r.root === dir)?.worktrees[0]?.dirty, 0);
  // ...a `fresh` caller waits for git...
  const fresh = (await listReposCached([parent], noPr, true)).repos;
  assert.equal(fresh.find((r) => r.root === dir)?.worktrees[0]?.dirty, 1);
  // ...and a write the host made forgets it for everyone.
  writeFileSync(path.join(dir, "c.txt"), "c\n");
  invalidateRepos();
  const after = (await listReposCached([parent], noPr)).repos;
  assert.equal(after.find((r) => r.root === dir)?.worktrees[0]?.dirty, 2);
});
