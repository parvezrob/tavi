import assert from "node:assert/strict";
import { once } from "node:events";
import { createServer, type IncomingMessage, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { mkdtempSync, mkdirSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import WebSocket, { WebSocketServer } from "ws";
import {
  PreviewRegistry,
  TICKET_COOKIE,
  createPreviewDoor,
  forwardHeaders,
  listProjectServers,
  loopbackPort,
  parseCwds,
  parseListeners,
  relativizeLocalhost,
  stopProjectServer,
  stripTicketCookie,
  ticketFrom,
  validPort,
} from "./preview.js";

// --- registry ---------------------------------------------------------------

test("open needs a listening port; the ticket comes back once and admits until closed", async () => {
  let clock = 1_000;
  const registry = new PreviewRegistry({ now: () => clock, probe: async (port) => (port === 5173 ? "127.0.0.1" : undefined) });

  const missing = await registry.open({ deviceId: "d1", port: 9, cwd: "/p" });
  assert.equal(missing.ok, false);
  assert.equal(!missing.ok && missing.status, 409);
  assert.equal(validPort("0"), undefined);
  assert.equal(validPort(70_000), undefined);
  assert.equal((await registry.open({ deviceId: "d1", port: "abc", cwd: "/p" })).ok, false);

  const opened = await registry.open({ deviceId: "d1", port: 5173, cwd: "/p" });
  assert.ok(opened.ok);
  if (!opened.ok) return;
  const { ticket, preview } = opened.opened;
  assert.match(ticket, /^[A-Za-z0-9_-]{43}$/);
  assert.equal(preview.address, "127.0.0.1");
  assert.equal(registry.admit(ticket)?.id, preview.id);
  assert.equal(registry.admit("not-a-ticket"), undefined);
  assert.equal(registry.admit(undefined), undefined);

  // Another device cannot touch or close it.
  assert.equal(registry.touch(preview.id, "d2"), undefined);
  assert.equal(registry.close(preview.id, "d2"), false);
  assert.deepEqual(registry.list("d2"), []);
  assert.equal(registry.list("d1").length, 1);

  clock += 60_000;
  assert.ok(registry.touch(preview.id, "d1"));
  assert.ok(registry.close(preview.id, "d1"));
  assert.equal(registry.admit(ticket), undefined);
  assert.equal(registry.size, 0);
});

test("a preview the phone stops keeping alive dies after the grace; traffic counts as keeping alive", async () => {
  let clock = 0;
  const registry = new PreviewRegistry({ now: () => clock, graceMs: 1_000, probe: async () => "::1" });
  const opened = await registry.open({ deviceId: "d1", port: 3000, cwd: "/p" });
  assert.ok(opened.ok);
  if (!opened.ok) return;
  clock = 900;
  assert.ok(registry.admit(opened.opened.ticket), "traffic before the grace passes");
  clock = 1_800;
  assert.ok(registry.admit(opened.opened.ticket), "the traffic at 900 reset the clock");
  clock = 3_000;
  assert.equal(registry.admit(opened.opened.ticket), undefined);
  assert.equal(registry.touch(opened.opened.preview.id, "d1"), undefined);
  assert.equal(registry.size, 0);
});

// --- header hygiene ---------------------------------------------------------

test("cookie parsing takes only our ticket and strips only our ticket", () => {
  assert.equal(ticketFrom(`a=1; ${TICKET_COOKIE}=T0K.en_-; b=2`), "T0K.en_-");
  assert.equal(ticketFrom("a=1"), undefined);
  assert.equal(ticketFrom(undefined), undefined);
  assert.equal(stripTicketCookie(`a=1; ${TICKET_COOKIE}=x; b=2`), "a=1; b=2");
  assert.equal(stripTicketCookie(`${TICKET_COOKIE}=x`), undefined);
});

test("the dev server sees a localhost browser: host/origin/referer rewritten, ticket gone, hop-by-hop dropped", () => {
  const headers = forwardHeaders(
    {
      host: "mac.tail.ts.net:8443",
      origin: "https://mac.tail.ts.net:8443",
      referer: "https://mac.tail.ts.net:8443/app/page?x=1",
      cookie: `${TICKET_COOKIE}=secret; theme=dark`,
      connection: "keep-alive",
      "accept-encoding": "gzip",
    },
    5173,
    false,
  );
  assert.equal(headers.host, "localhost:5173");
  assert.equal(headers.origin, "http://localhost:5173");
  assert.equal(headers.referer, "http://localhost:5173/app/page?x=1");
  assert.equal(headers.cookie, "theme=dark");
  assert.equal(headers.connection, undefined);
  assert.equal(headers["accept-encoding"], "gzip");
  assert.equal(headers["x-forwarded-host"], "mac.tail.ts.net:8443");
  assert.equal(headers["x-forwarded-proto"], "https");

  const upgrade = forwardHeaders({ host: "h", connection: "Upgrade", upgrade: "websocket", cookie: `${TICKET_COOKIE}=s` }, 5173, true);
  assert.equal(upgrade.connection, "Upgrade");
  assert.equal(upgrade.upgrade, "websocket");
  assert.equal(upgrade.cookie, undefined);
});

test("a redirect to the dev server's own localhost becomes a relative one; others pass", () => {
  assert.equal(relativizeLocalhost("http://localhost:5173/about/", 5173), "/about/");
  assert.equal(relativizeLocalhost("http://127.0.0.1:5173", 5173), "/");
  assert.equal(relativizeLocalhost("http://[::1]:5173/x?y=1", 5173), "/x?y=1");
  assert.equal(relativizeLocalhost("http://localhost:3000/", 5173), "http://localhost:3000/");
  assert.equal(relativizeLocalhost("/relative", 5173), "/relative");
  assert.equal(relativizeLocalhost("https://example.com/", 5173), "https://example.com/");
});

// --- the door, end to end ---------------------------------------------------

test("the door refuses without a ticket, proxies HTTP with absolute paths, and pipes WebSockets", async () => {
  const seen: IncomingMessage[] = [];
  const devServer = createServer((request, response) => {
    seen.push(request);
    if (request.url === "/redirect") {
      response.writeHead(302, { Location: `http://localhost:${devPort()}/landed` }).end();
      return;
    }
    if (request.url === "/echo") {
      let body = "";
      request.on("data", (chunk) => (body += chunk));
      request.on("end", () => response.writeHead(200, { "Content-Type": "text/plain" }).end(`echo:${body}`));
      return;
    }
    response.writeHead(200, { "Content-Type": "application/javascript", "X-Dev": "1" }).end(`// ${request.url}`);
  });
  const wss = new WebSocketServer({ server: devServer });
  wss.on("connection", (socket, request) => {
    socket.on("message", (data) => socket.send(`pong:${data} host=${request.headers.host} origin=${request.headers.origin ?? "-"}`));
  });
  await listen(devServer);
  const devPort = () => (devServer.address() as AddressInfo).port;

  const registry = new PreviewRegistry({ probe: async () => "127.0.0.1" });
  const door = createPreviewDoor({ registry });
  await listen(door);
  const origin = `http://127.0.0.1:${(door.address() as AddressInfo).port}`;

  try {
    const refused = await fetch(`${origin}/assets/index.js`);
    assert.equal(refused.status, 401);
    assert.match(refused.headers.get("content-type") ?? "", /text\/html/);
    assert.match(await refused.text(), /Open this from Tavi/);
    assert.equal(seen.length, 0, "nothing reached the dev server");

    const opened = await registry.open({ deviceId: "d1", port: devPort(), cwd: "/p" });
    assert.ok(opened.ok);
    if (!opened.ok) return;
    const cookie = `${TICKET_COOKIE}=${opened.opened.ticket}; theme=dark`;

    const asset = await fetch(`${origin}/assets/index.js?v=2`, { headers: { cookie, host: "mac.ts.net:8443" } });
    assert.equal(asset.status, 200);
    assert.equal(asset.headers.get("x-dev"), "1");
    assert.equal(await asset.text(), "// /assets/index.js?v=2");
    const reached = seen.at(-1);
    assert.equal(reached?.headers.host, `localhost:${devPort()}`);
    assert.equal(reached?.headers.cookie, "theme=dark");
    assert.equal(reached?.headers["x-forwarded-proto"], "https");

    const posted = await fetch(`${origin}/echo`, { method: "POST", body: "hello", headers: { cookie } });
    assert.equal(await posted.text(), "echo:hello");

    const redirected = await fetch(`${origin}/redirect`, { headers: { cookie }, redirect: "manual" });
    assert.equal(redirected.status, 302);
    assert.equal(redirected.headers.get("location"), "/landed");

    const badTicket = await fetch(`${origin}/`, { headers: { cookie: `${TICKET_COOKIE}=nope` } });
    assert.equal(badTicket.status, 401);

    const socket = new WebSocket(`${origin.replace("http", "ws")}/hmr`, { headers: { cookie, origin: "https://mac.ts.net:8443" } });
    await once(socket, "open");
    socket.send("hi");
    const [reply] = (await once(socket, "message")) as [Buffer];
    assert.equal(reply.toString(), `pong:hi host=localhost:${devPort()} origin=http://localhost:${devPort()}`);
    socket.close();
    await once(socket, "close");

    const noTicketSocket = new WebSocket(`${origin.replace("http", "ws")}/hmr`);
    const [error] = (await once(noTicketSocket, "error")) as [Error];
    assert.match(error.message, /401/);

    // The dev server stops: a plain page, not a hang.
    await close(devServer);
    const gone = await fetch(`${origin}/`, { headers: { cookie } });
    assert.equal(gone.status, 502);
    assert.match(await gone.text(), /Nothing is answering on localhost:/);
  } finally {
    registry.stop();
    await close(door);
    if (devServer.listening) await close(devServer);
    wss.close();
  }
});

// --- discovery --------------------------------------------------------------

const LSOF_LISTENERS = [
  "p599",
  "cControlCenter",
  "f10",
  "n*:7000",
  "p4242",
  "cnode",
  "f22",
  "n127.0.0.1:5173",
  "f23",
  "n[::1]:5173",
  "p4300",
  "cpython3.12",
  "f5",
  "n*:8000",
  "p4400",
  "cnode",
  "f9",
  "n192.168.1.20:3001",
  "",
].join("\n");

test("lsof output → loopback listeners; LAN-only binds are not previewable", () => {
  const listeners = parseListeners(LSOF_LISTENERS);
  assert.deepEqual(
    listeners.map((listener) => [listener.pid, listener.command, listener.port]),
    [
      [599, "ControlCenter", 7000],
      [4242, "node", 5173],
      [4242, "node", 5173],
      [4300, "python3.12", 8000],
    ],
  );
  assert.equal(loopbackPort("192.168.1.20:3001"), undefined);
  assert.equal(loopbackPort("[::]:4000"), 4000);
  assert.equal(loopbackPort("0.0.0.0:80"), 80);
  assert.deepEqual([...parseCwds("p4242\nfcwd\nn/Users/me/app\np4300\nfcwd\nn/Users/me/app/api\n")], [
    [4242, "/Users/me/app"],
    [4300, "/Users/me/app/api"],
  ]);
});

test("project servers: cwd inside the project or a parent of it, inside roots; one row per port", async () => {
  const root = realpathSync(mkdtempSync(path.join(tmpdir(), "tavi-preview-")));
  const app = path.join(root, "app");
  const api = path.join(app, "api");
  const elsewhere = path.join(root, "other");
  for (const dir of [api, elsewhere]) mkdirSync(dir, { recursive: true });
  const deps = {
    listListeners: async () => LSOF_LISTENERS,
    listCwds: async (pids: number[]) => {
      assert.deepEqual(pids, [599, 4242, 4300]);
      return `p599\nfcwd\nn/\np4242\nfcwd\nn${app}\np4300\nfcwd\nn${api}\n`;
    },
    realpath: async (target: string) => realpathSync(target),
  };
  const fromApp = await listProjectServers(app, [root], deps);
  assert.ok(fromApp.available);
  if (!fromApp.available) return;
  assert.deepEqual(
    fromApp.servers.map((server) => [server.port, server.pid, server.command, server.cwd]),
    [
      [5173, 4242, "node", app],
      [8000, 4300, "python3.12", api],
    ],
  );
  // From the api folder the monorepo's root server (cwd = parent) still counts.
  const fromApi = await listProjectServers(api, [root], deps);
  assert.ok(fromApi.available && fromApi.servers.map((server) => server.port).join(",") === "5173,8000");
  // A different project sees none of them; ControlCenter's cwd `/` never counts.
  const fromElsewhere = await listProjectServers(elsewhere, [root], deps);
  assert.ok(fromElsewhere.available && fromElsewhere.servers.length === 0);
  // Outside the roots: nothing, even when related.
  const outsideRoots = await listProjectServers(app, [elsewhere], deps);
  assert.ok(outsideRoots.available && outsideRoots.servers.length === 0);

  const noLsof = await listProjectServers(app, [root], {
    ...deps,
    listListeners: async () => {
      throw Object.assign(new Error("nope"), { code: "ENOENT" });
    },
  });
  assert.ok(!noLsof.available);
  if (!noLsof.available) assert.match(noLsof.reason, /lsof is not installed/);
});

test("stop server: re-discovers, kills only this project's owner of that port, never a stranger", async () => {
  const root = realpathSync(mkdtempSync(path.join(tmpdir(), "tavi-preview-")));
  const app = path.join(root, "app");
  mkdirSync(app, { recursive: true });
  const killed: number[] = [];
  const deps = {
    listListeners: async () => LSOF_LISTENERS,
    listCwds: async () => `p599\nfcwd\nn/\np4242\nfcwd\nn${app}\np4300\nfcwd\nn/somewhere/else\n`,
    realpath: async (target: string) => (target.startsWith("/somewhere") ? target : realpathSync(target)),
    kill: (pid: number) => killed.push(pid),
  };
  const stopped = await stopProjectServer(app, 5173, [root], deps);
  assert.deepEqual(stopped, { ok: true, pid: 4242, command: "node" });
  const other = await stopProjectServer(app, 7000, [root], deps);
  assert.equal(other.ok, false);
  const notOurs = await stopProjectServer(app, 8000, [root], deps);
  assert.equal(notOurs.ok, false);
  assert.deepEqual(killed, [4242]);
});

async function listen(server: Server): Promise<void> {
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
}

async function close(server: Server): Promise<void> {
  server.closeAllConnections?.();
  await new Promise<void>((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
}
