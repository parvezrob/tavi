import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { isWithinRoots, mergeRecentProjects, normalizeProjectPath, ProjectHistory } from "./projects.js";

function scratch(): string {
  return mkdtempSync(path.join(tmpdir(), "tavi-projects-"));
}

function directory(parent: string, name: string): string {
  const created = path.join(parent, name);
  mkdirSync(created, { recursive: true });
  return created;
}

function silent(): ProjectHistory {
  return new ProjectHistory(scratch(), undefined, () => {});
}

test("a project path must be an existing absolute directory", () => {
  const root = scratch();
  const file = path.join(root, "notes.txt");
  writeFileSync(file, "hello");

  assert.deepEqual(normalizeProjectPath(root), { ok: true, path: root });
  assert.equal(normalizeProjectPath("relative/path").ok, false);
  assert.equal(normalizeProjectPath("").ok, false);
  assert.equal(normalizeProjectPath(`${root}\0/etc`).ok, false);
  assert.equal(normalizeProjectPath(file).ok, false);
  assert.equal(normalizeProjectPath(path.join(root, "missing")).ok, false);
});

test("a project path is normalized before it is used", () => {
  const root = scratch();
  assert.deepEqual(normalizeProjectPath(`  ${root}/./sub/..  `), { ok: true, path: root });
});

test("root containment covers the root itself and its descendants only", () => {
  const roots = ["/Users/dev/Projects", "/Users/dev/Code"];

  assert.equal(isWithinRoots("/Users/dev/Projects", roots), true);
  assert.equal(isWithinRoots("/Users/dev/Projects/api", roots), true);
  assert.equal(isWithinRoots("/Users/dev/Code/api/packages/core", roots), true);
  assert.equal(isWithinRoots("/Users/dev", roots), false);
  assert.equal(isWithinRoots("/Users/dev/Projects-secret", roots), false);
  assert.equal(isWithinRoots("/Users/dev/Projects/../elsewhere", roots), false);
  assert.equal(isWithinRoots("/private/tmp/scratch", roots), false);
  assert.equal(isWithinRoots("/Users/dev/Projects/api", []), false);
});

// macOS accepts either spelling for the same directory, so a root configured
// in one case and a folder chosen in another must still match — otherwise
// every create under that root would demand the outside-roots confirmation.
test("root containment ignores case and Unicode spelling differences", () => {
  assert.equal(isWithinRoots("/Users/Dev/Projects/API", ["/users/dev/projects"]), true);
  assert.equal(isWithinRoots("/users/dev/projects/api", ["/Users/Dev/Projects"]), true);
  assert.equal(isWithinRoots("/Users/dev/Projects/café", ["/Users/dev/Projects"]), true);
  assert.equal(isWithinRoots("/Users/dev/Projects/café", ["/Users/dev/Projects/café"]), true);
});

test("remembered projects survive a round trip, newest first and capped", () => {
  const stateDir = scratch();
  let tick = 0;
  const history = new ProjectHistory(
    stateDir,
    // biome-ignore lint/suspicious/noAssignInExpressions: a clock that advances a second per call, in one expression.
    () => new Date(1_700_000_000_000 + (tick += 1_000)),
    () => {},
  );

  for (let index = 0; index < 15; index += 1) {
    history.remember(`/Users/dev/Projects/repo-${index}`);
  }

  const stored = history.list();
  assert.equal(stored.length, 12);
  assert.equal(stored[0]?.path, "/Users/dev/Projects/repo-14");
  assert.equal(stored.at(-1)?.path, "/Users/dev/Projects/repo-3");

  // Re-choosing an older folder moves it back to the front instead of
  // duplicating it.
  history.remember("/Users/dev/Projects/repo-5");
  const reordered = new ProjectHistory(stateDir).list();
  assert.equal(reordered[0]?.path, "/Users/dev/Projects/repo-5");
  assert.equal(reordered.filter((entry) => entry.path === "/Users/dev/Projects/repo-5").length, 1);
});

test("one directory spelled two ways is remembered once", () => {
  const stateDir = scratch();
  const history = new ProjectHistory(stateDir, undefined, () => {});

  history.remember("/Users/dev/Projects/MyRepo");
  history.remember("/Users/dev/Projects/myrepo");
  history.remember("/Users/dev/Projects/café");
  history.remember("/Users/dev/Projects/café");

  assert.equal(history.list().length, 2);
  // The latest spelling wins, so the picker shows what was chosen last.
  assert.equal(history.list()[1]?.path, "/Users/dev/Projects/myrepo");
});

test("the remembered-projects file is versioned and owner-only", () => {
  const stateDir = scratch();
  new ProjectHistory(stateDir, undefined, () => {}).remember("/Users/dev/Projects/api");

  const file = path.join(stateDir, "projects.json");
  assert.equal(statSync(file).mode & 0o777, 0o600);
  assert.equal((JSON.parse(readFileSync(file, "utf8")) as { version: number }).version, 1);
});

test("an unreadable, damaged, or foreign history file reads as empty and says so", () => {
  const stateDir = scratch();
  const file = path.join(stateDir, "projects.json");
  const reported: string[] = [];
  const history = new ProjectHistory(stateDir, undefined, (message) => reported.push(message));

  writeFileSync(file, "{ not json");
  assert.deepEqual(history.list(), []);

  // A list written by a future version is never reinterpreted as this one.
  writeFileSync(file, JSON.stringify({ version: 99, recent: [{ path: "/a", lastUsedAt: "t" }] }));
  assert.deepEqual(history.list(), []);

  writeFileSync(file, JSON.stringify({ version: 1, recent: "nope" }));
  assert.deepEqual(history.list(), []);

  assert.equal(reported.length, 3);
  assert.equal(
    reported.every((message) => message.includes(file)),
    true,
  );

  // Entries the host cannot trust are dropped, the rest survive.
  writeFileSync(
    file,
    JSON.stringify({
      version: 1,
      recent: [{ path: 7 }, { path: "sneaky", lastUsedAt: "t" }, { path: "/a", lastUsedAt: "t" }],
    }),
  );
  assert.deepEqual(history.list(), [{ path: "/a", lastUsedAt: "t" }]);
});

test("a missing history file reads as empty without a complaint or a file", () => {
  const stateDir = scratch();
  const reported: string[] = [];
  const history = new ProjectHistory(stateDir, undefined, (message) => reported.push(message));

  assert.deepEqual(history.list(), []);
  assert.deepEqual(reported, []);
  assert.throws(() => readFileSync(path.join(stateDir, "projects.json"), "utf8"));
});

test("a history that cannot be saved is reported, not swallowed", () => {
  const stateDir = scratch();
  const reported: string[] = [];
  chmodSync(stateDir, 0o500);

  try {
    new ProjectHistory(stateDir, undefined, (message) => reported.push(message)).remember("/Users/dev/api");
    assert.equal(reported.length, 1);
    assert.match(reported[0] ?? "", /could not save/);
    // The agent still started; only the convenience list was lost.
    assert.match(reported[0] ?? "", /still started/);
  } finally {
    chmodSync(stateDir, 0o700);
  }
});

test("recent projects merge live agent folders with remembered choices", () => {
  const root = scratch();
  const api = directory(root, "api");
  const web = directory(root, "web");
  const outside = scratch();
  const notes = directory(outside, "notes");

  const merged = mergeRecentProjects(
    [
      { path: api, lastUsedAt: "2026-08-30T10:00:00.000Z" },
      { path: web, lastUsedAt: "2026-08-29T10:00:00.000Z" },
      { path: outside, lastUsedAt: "2026-08-28T10:00:00.000Z" },
    ],
    [web, notes],
    [root],
  );

  // Folders with a live agent lead; the rest follow by most recent choice.
  assert.deepEqual(
    merged.map((entry) => entry.path),
    [web, notes, api, outside],
  );
  assert.deepEqual(
    merged.map((entry) => entry.active),
    [true, true, false, false],
  );
  assert.deepEqual(
    merged.map((entry) => entry.withinRoots),
    [true, false, true, false],
  );
  assert.equal(merged[0]?.name, "web");
  // An agent's folder the host never launched carries no invented history.
  assert.equal(merged[1]?.lastUsedAt, undefined);
});

test("a remembered folder that no longer exists is not offered", () => {
  const root = scratch();
  const api = directory(root, "api");

  const merged = mergeRecentProjects(
    [
      { path: api, lastUsedAt: "2026-08-30T10:00:00.000Z" },
      { path: path.join(root, "deleted"), lastUsedAt: "2026-08-31T10:00:00.000Z" },
    ],
    [],
    [root],
  );

  assert.deepEqual(
    merged.map((entry) => entry.path),
    [api],
  );
});

test("merging tolerates duplicate, differently spelled, and empty agent folders", () => {
  const root = scratch();
  const api = directory(root, "api");

  const merged = mergeRecentProjects(
    [{ path: api, lastUsedAt: "2026-08-30T10:00:00.000Z" }],
    ["", api, `${api}/`, api.toUpperCase()],
    [root],
  );

  assert.equal(merged.length, 1);
  assert.equal(merged[0]?.active, true);
});

test("silent construction still works for callers that do not inject a reporter", () => {
  assert.deepEqual(silent().list(), []);
});
