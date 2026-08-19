import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import test from "node:test";
import {
  chunkTerminalOutput,
  MAX_TERMINAL_FRAME_BYTES,
  parseClientTerminalMessage,
} from "./protocol.js";

interface ProtocolFixture {
  clientValid: unknown[];
  clientInvalid: unknown[];
}

test("terminal client-message parser accepts the shared valid corpus", async () => {
  const fixture = await loadFixture();
  for (const message of fixture.clientValid) {
    assert.notEqual(parseClientTerminalMessage(message), undefined);
  }
});

test("terminal client-message parser rejects the shared malformed corpus", async () => {
  const fixture = await loadFixture();
  for (const message of fixture.clientInvalid) {
    assert.equal(parseClientTerminalMessage(message), undefined);
  }
});

test("terminal output chunks preserve Unicode and bound serialized frames", () => {
  const output = `${"\u001b[2K\r".repeat(20_000)}${"বাংলা · 日本語 · 👩🏽‍💻\r\n".repeat(2_000)}`;
  const chunks = chunkTerminalOutput(output);

  assert.ok(chunks.length > 1);
  assert.equal(chunks.join(""), output);
  for (const data of chunks) {
    assert.ok(
      Buffer.byteLength(JSON.stringify({ type: "output", data })) <= MAX_TERMINAL_FRAME_BYTES,
    );
  }
});

async function loadFixture(): Promise<ProtocolFixture> {
  const path = fileURLToPath(
    new URL("../../../protocol/fixtures/terminal-v1/messages.json", import.meta.url),
  );
  return JSON.parse(await readFile(path, "utf8")) as ProtocolFixture;
}
