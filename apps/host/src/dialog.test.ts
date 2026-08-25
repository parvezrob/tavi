import assert from "node:assert/strict";
import test from "node:test";
import { parsePermissionDialog } from "./dialog.js";

test("parses a Claude permission dialog with a highlighted option", () => {
  const text = [
    " Bash command",
    " echo hello",
    "",
    " Do you want to proceed?",
    " ❯ 1. Yes",
    "   2. Yes, and don't ask again for echo commands",
    "   3. No, and tell Claude what to do differently",
    "",
    " Enter to confirm · Esc to cancel",
  ].join("\n");

  const dialog = parsePermissionDialog(text);

  assert.ok(dialog);
  assert.equal(dialog?.prompt, "Do you want to proceed?");
  assert.deepEqual(dialog?.options, [
    { index: 1, label: "Yes", selected: true },
    { index: 2, label: "Yes, and don't ask again for echo commands", selected: false },
    { index: 3, label: "No, and tell Claude what to do differently", selected: false },
  ]);
});

test("parses a Bash permission dialog whose footer omits 'Enter to confirm'", () => {
  // Captured live: tool-permission dialogs use a different footer than the
  // trust dialog and must still be detected.
  const text = [
    " Bash command",
    "",
    "   touch approve-test.txt",
    "   Create an empty file named approve-test.txt",
    "",
    " Do you want to proceed?",
    " ❯ 1. Yes",
    "   2. Yes, and always allow access to /private/tmp/x from this project",
    "   3. No",
    "",
    " Esc to cancel · Tab to amend · ctrl+e to explain",
  ].join("\n");

  const dialog = parsePermissionDialog(text);

  assert.ok(dialog, "the Bash permission dialog must be detected");
  assert.equal(dialog?.prompt, "Do you want to proceed?");
  assert.equal(dialog?.options.length, 3);
  assert.equal(dialog?.options[0]?.selected, true);
  assert.equal(dialog?.options[2]?.label, "No");
});

test("parses the trust-folder dialog verbatim", () => {
  const text = [
    " Accessing workspace:",
    " /private/tmp/project",
    "",
    " ❯ 1. Yes, I trust this folder",
    "   2. No, exit",
    "",
    " Enter to confirm · Esc to cancel",
  ].join("\n");

  const dialog = parsePermissionDialog(text);

  assert.equal(dialog?.options.length, 2);
  assert.equal(dialog?.options[0]?.selected, true);
  assert.equal(dialog?.options[1]?.label, "No, exit");
});

test("detects a menu by its selection arrow even with no known footer", () => {
  // A future prompt type whose footer we have never seen still parses,
  // because the highlighted option list is the real signal.
  const text = [
    " Some new project decision?",
    "   1. Option A",
    " ❯ 2. Option B",
    "   3. Option C",
    "",
    " press number to choose",
  ].join("\n");

  const dialog = parsePermissionDialog(text);

  assert.equal(dialog?.options.length, 3);
  assert.equal(dialog?.options[1]?.selected, true);
});

test("returns undefined for a numbered list with neither an arrow nor a footer", () => {
  const text = [" 1. first", " 2. second", " 3. third", "", " ctx 0/200k"].join("\n");
  assert.equal(parsePermissionDialog(text), undefined);
});

test("returns undefined for prose that merely lists a numbered item", () => {
  const text = [
    " Here is the plan:",
    " 1. Read the file",
    "",
    " I'll press Enter to confirm once you esc out — just kidding.",
  ].join("\n");
  assert.equal(parsePermissionDialog(text), undefined);
});

test("requires at least two options", () => {
  const text = [" ❯ 1. Only choice", "", " Enter to confirm · Esc to cancel"].join("\n");
  assert.equal(parsePermissionDialog(text), undefined);
});

test("no option is marked selected when the arrow is absent", () => {
  const text = ["   1. Yes", "   2. No", "", " Enter to confirm · Esc to cancel"].join("\n");
  const dialog = parsePermissionDialog(text);
  assert.equal(dialog?.options.every((option) => !option.selected), true);
});
