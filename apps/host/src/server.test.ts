import assert from "node:assert/strict";
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import test from "node:test";
import type { HostConfig } from "./config.js";
import { createDeckServer } from "./server.js";
import type { TmuxService } from "./tmux.js";

const config: HostConfig = {
  bindHost: "127.0.0.1",
  port: 0,
  token: "test-token-that-is-long-enough",
  shell: "/bin/sh",
  tmuxBin: "tmux",
  roots: [],
  stateDir: "/tmp",
  machineName: "test-host",
};

test("the host is API-only and does not serve a browser client", async () => {
  await withServer(async (origin) => {
    const response = await fetch(`${origin}/`);

    assert.equal(response.status, 404);
    assert.deepEqual(await response.json(), { error: "Not found." });
  });
});

test("the unauthenticated health endpoint remains available", async () => {
  await withServer(async (origin) => {
    const response = await fetch(`${origin}/api/health`);
    const body = (await response.json()) as { ok: boolean; version: string };

    assert.equal(response.status, 200);
    assert.equal(body.ok, true);
    assert.match(body.version, /^\d+\.\d+\.\d+$/);
  });
});

async function withServer(run: (origin: string) => Promise<void>): Promise<void> {
  const server = await createDeckServer({ config, tmux: {} as TmuxService });
  await listen(server);

  try {
    const address = server.address() as AddressInfo;
    await run(`http://127.0.0.1:${address.port}`);
  } finally {
    await close(server);
  }
}

function listen(server: Server): Promise<void> {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
}

function close(server: Server): Promise<void> {
  return new Promise((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
}
