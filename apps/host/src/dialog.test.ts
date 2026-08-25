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

test("returns undefined without the confirm/cancel footer", () => {
  const text = [" 1. first", " 2. second", " ❯ 3. third", "", " ctx 0/200k"].join("\n");
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
