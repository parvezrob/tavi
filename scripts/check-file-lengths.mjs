#!/usr/bin/env node
// The 400-line rule for host source, enforced instead of remembered (#96
// item 10). A file past it has stopped having one reason to change: every
// grab-bag this repository has grown — bootstrap, worktrees, herdr — grew
// one accepted line at a time.
//
// Tests get a far looser cap: a suite is a list, and splitting one only to
// satisfy a number hides which behaviours are covered together.

import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SOURCE_LIMIT = 400;
const TEST_LIMIT = 1_500;

// Empty since #98 split the six grab-bags #96 item 8 named, and it stays
// empty: a file over the limit is split, never allowlisted.
const ALLOWED = [];

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const sourceDir = path.join(root, "apps", "host", "src");

function walk(directory) {
  const found = [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const full = path.join(directory, entry.name);
    if (entry.isDirectory()) found.push(...walk(full));
    else if (entry.name.endsWith(".ts")) found.push(full);
  }
  return found;
}

const failures = [];
for (const file of walk(sourceDir).sort()) {
  // Newlines, the way `wc -l` counts them, so the number here is the number a person checks.
  const lines = readFileSync(file, "utf8").split("\n").length - 1;
  const isTest = file.endsWith(".test.ts");
  const limit = isTest ? TEST_LIMIT : SOURCE_LIMIT;
  if (lines <= limit) continue;
  if (!isTest && ALLOWED.includes(path.relative(sourceDir, file))) continue;
  failures.push(`${path.relative(root, file)}: ${lines} lines (limit ${limit})`);
}

if (failures.length > 0) {
  console.error(`${failures.length} file(s) over the length limit — split them, do not extend the allowlist:`);
  for (const failure of failures) console.error(`  ${failure}`);
  process.exit(1);
}
console.log(`File lengths OK (${SOURCE_LIMIT} source, ${TEST_LIMIT} test; ${ALLOWED.length} allowlisted).`);
