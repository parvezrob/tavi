import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { HerdrService } from "./herdr.js";
import { spawnAttachmentTerminal } from "./terminal-bridge.js";
import { testConfig } from "./testing/config.js";
import type { AttachCommand, HerdrAgentInfo } from "./types.js";

// Asks a real herdr whether it still honours what herdr.ts assumes: the
// gates, the refusals, and the Terminal hand-back, each found live and each
// expensive to rediscover. Skipped unless TAVI_LIVE_HERDR=1, because it
// starts real agents in real tabs on the machine it runs on.
const skip = process.env.TAVI_LIVE_HERDR === "1" ? false : "set TAVI_LIVE_HERDR=1 to run against a real herdr";

// The oldest protocol herdr.ts accepts (MIN_PROTOCOL there).
const MIN_PROTOCOL = 17;
// loadConfig()'s rule, without minting a host token to read it.
const socketPath = process.env.TAVI_HERDR_SOCKET ?? path.join(homedir(), ".config", "herdr", "herdr.sock");
const REFUSAL = /already has an attached client/i;

test("herdr honours what herdr.ts assumes", { skip }, async (t) => {
  const herdr = new HerdrService({ socketPath });
  const cwd = mkdtempSync(path.join(tmpdir(), "tavi-herdr-contract-"));
  const openTabs: string[] = [];
  const attachments: Attachment[] = [];
  t.after(async () => {
    for (const attachment of attachments) attachment.kill();
    for (const tabId of openTabs) await herdr.closeTab(tabId);
    rmSync(cwd, { recursive: true, force: true });
  });

  // The gate listAgents() fails closed on: protocol at least 17, and rows that still carry pane_id and agent_status.
  const listed = await herdr.listAgents();
  if (!listed.available) assert.fail(`agent.list must pass the protocol and shape gate: ${listed.reason}`);
  assert.ok((listed.protocol ?? 0) >= MIN_PROTOCOL, `protocol ${listed.protocol} is older than ${MIN_PROTOCOL}`);
  assert.ok(
    listed.agents.every((agent) => agent.id !== ""),
    "every agent.list entry carries a pane_id",
  );

  const created = await herdr.createTab({ agent: "shell", cwd });
  if (!created.created) assert.fail(`tab.create plus pane.report_agent must produce a Terminal: ${created.reason}`);
  openTabs.push(created.tabId);
  const paneId = created.paneId;

  // A pane this young refuses agent.send_keys, which is why the phone's live tests type through the surface instead.
  const prompted = await herdr.promptAgent(paneId, "echo tavi-contract");
  assert.equal(prompted.submitted, false, "a seconds-old pane refuses a typed prompt");

  // herdr reads "idle after having worked" as done, so herdr.ts maps done back to idle for a shell.
  assert.deepEqual(identity(await agentRow(herdr, paneId)), { agent: "shell", status: "idle" });

  // tab.rename applies the label and listAgents joins tab.list into every row as tabLabel (#55).
  const label = `tavi contract ${Date.now()}`;
  const renamed = await herdr.renameTab(created.tabId, label);
  if (!renamed.renamed) assert.fail(`tab.rename must apply the label: ${renamed.reason}`);
  assert.equal(renamed.label, label, "tab.rename answers with the applied label");
  assert.equal((await agentRow(herdr, paneId))?.tabLabel, label, "the renamed label reaches agent.list");

  // Released, a pane with nothing running leaves agent.list while pane.get still answers — the gap herdr-events.ts carries a row across.
  await herdr.releaseShellAuthority(paneId);
  await waitUntil("the released pane to leave agent.list", async () => (await agentRow(herdr, paneId)) === undefined);
  assert.equal(await herdr.paneExists(paneId), true, "a pane out of agent.list still answers pane.get");
  await herdr.reportShellPane(paneId);
  await waitUntil("the re-reported pane to list again", async () => (await agentRow(herdr, paneId)) !== undefined);

  // The report outranks herdr's own detection for the pane's life (#66): a detected claude still reads as the reported shell, and only release hands it back.
  const started = await herdr.createTab({ agent: "claude", cwd });
  if (!started.created) assert.fail(`agent.start must launch a detectable agent: ${started.reason}`);
  openTabs.push(started.tabId);
  await waitUntil(
    "herdr to detect the started agent",
    async () => (await agentRow(herdr, started.paneId))?.agent === "claude",
  );
  await herdr.reportShellPane(started.paneId);
  assert.equal((await agentRow(herdr, started.paneId))?.agent, "shell", "a report relabels a pane herdr detected");
  await herdr.releaseShellAuthority(started.paneId);
  await waitUntil(
    "detection to take the released pane back",
    async () => (await agentRow(herdr, started.paneId))?.agent === "claude",
  );

  // `--takeover` always: herdr keeps a departed client registered for a moment, so a plain attach after a drop is refused.
  const attach = herdr.attachCommand(paneId);
  const held = await attachPane(attachments, attach);
  await waitUntil("the first attach to paint the pane", async () => held.output().length > 0);
  const plain = await attachPane(attachments, { ...attach, args: attach.args.filter((arg) => arg !== "--takeover") });
  await waitUntil("the plain attach to be refused", async () => plain.exited() || REFUSAL.test(plain.output()));
  assert.ok(plain.exited() || REFUSAL.test(plain.output()), "a plain attach is refused while a client is registered");
  const takeover = await attachPane(attachments, attach);
  await waitUntil("the takeover attach to paint the pane", async () => takeover.output().length > 0);
  assert.equal(takeover.exited(), false, "--takeover attaches over the client herdr still has registered");
});

interface Attachment {
  output(): string;
  exited(): boolean;
  kill(): void;
}

// The production spawn path, so the contract covers what the host runs. node-pty is imported lazily: a skipped run must not need the native module.
async function attachPane(attachments: Attachment[], command: AttachCommand): Promise<Attachment> {
  const pty = await import("node-pty");
  const child = spawnAttachmentTerminal(command, testConfig(), pty.spawn);
  let output = "";
  let exited = false;
  child.onData((chunk) => {
    output += chunk;
  });
  child.onExit(() => {
    exited = true;
  });
  const attachment: Attachment = {
    output: () => output,
    exited: () => exited,
    kill: () => {
      if (!exited) child.kill();
    },
  };
  attachments.push(attachment);
  return attachment;
}

async function agentRow(herdr: HerdrService, paneId: string): Promise<HerdrAgentInfo | undefined> {
  const lookup = await herdr.findAgent(paneId);
  return lookup.available ? lookup.agent : undefined;
}

function identity(agent: HerdrAgentInfo | undefined): { agent: string; status: string } | undefined {
  return agent && { agent: agent.agent, status: agent.status };
}

async function waitUntil(what: string, ready: () => Promise<boolean>, timeoutMilliseconds = 8_000): Promise<void> {
  const deadline = Date.now() + timeoutMilliseconds;
  while (!(await ready())) {
    if (Date.now() > deadline) assert.fail(`timed out waiting for ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
}
