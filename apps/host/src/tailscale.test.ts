import assert from "node:assert/strict";
import { test } from "node:test";

import { callerAddress, connectionPath, describePeerPath, isTailnetAddress } from "./tailscale.js";

const status = {
  Self: { TailscaleIPs: ["100.70.236.37", "fd7a:115c:a1e0::1"], CurAddr: "", Relay: "sin" },
  Peer: {
    nodekey1: { HostName: "iphone", TailscaleIPs: ["100.102.71.0"], CurAddr: "192.168.0.228:41641", Relay: "blr" },
    nodekey2: { HostName: "ubuntu", TailscaleIPs: ["100.118.42.48"], CurAddr: "", Relay: "blr" },
    nodekey3: { HostName: "pi", TailscaleIPs: ["100.67.190.5"], CurAddr: "", Relay: "" },
  },
};

test("describePeerPath: direct when the peer has a current address, relay when only a DERP region, unknown otherwise", () => {
  assert.deepEqual(describePeerPath(status, "100.102.71.0"), { path: "direct" });
  assert.deepEqual(describePeerPath(status, "100.118.42.48"), { path: "relay", relay: "blr" });
  assert.deepEqual(describePeerPath(status, "100.67.190.5"), { path: "unknown" });
  // A stranger, a broken document, and the computer asking about itself.
  assert.deepEqual(describePeerPath(status, "100.99.99.99"), { path: "unknown" });
  assert.deepEqual(describePeerPath("nonsense", "100.102.71.0"), { path: "unknown" });
  assert.deepEqual(describePeerPath(null, "100.102.71.0"), { path: "unknown" });
  assert.deepEqual(describePeerPath(status, "100.70.236.37"), { path: "direct" });
});

test("callerAddress: the first X-Forwarded-For hop behind Serve, the socket otherwise, tailnet addresses only", () => {
  const behindServe = { headers: { "x-forwarded-for": "100.102.71.0, 127.0.0.1" }, socket: { remoteAddress: "127.0.0.1" } };
  assert.equal(callerAddress(behindServe as never), "100.102.71.0");
  const direct = { headers: {}, socket: { remoteAddress: "::ffff:100.102.71.0" } };
  assert.equal(callerAddress(direct as never), "100.102.71.0");
  const localhost = { headers: {}, socket: { remoteAddress: "127.0.0.1" } };
  assert.equal(callerAddress(localhost as never), null);
  // A spoofed header naming a non-tailnet address is not asked about.
  const spoofed = { headers: { "x-forwarded-for": "8.8.8.8" }, socket: { remoteAddress: "127.0.0.1" } };
  assert.equal(callerAddress(spoofed as never), null);
  assert.equal(isTailnetAddress("100.64.0.1"), true);
  assert.equal(isTailnetAddress("100.127.255.254"), true);
  assert.equal(isTailnetAddress("100.128.0.1"), false);
  assert.equal(isTailnetAddress("fd7a:115c:a1e0:ab12::1"), true);
  assert.equal(isTailnetAddress("192.168.0.1"), false);
});

test("connectionPath: asks tailscale once per window, and any failure is unknown", async () => {
  let calls = 0;
  const runner = async (args: string[]) => {
    calls += 1;
    assert.deepEqual(args, ["status", "--json"]);
    return { stdout: JSON.stringify(status) };
  };
  const request = { headers: { "x-forwarded-for": "100.102.71.0" }, socket: { remoteAddress: "127.0.0.1" } } as never;
  // The route never waits: the first answer is unknown while the lookup
  // runs in the background; tests wait for it.
  assert.deepEqual(await connectionPath(request, runner), { path: "unknown" });
  assert.deepEqual(await connectionPath(request, runner, true), { path: "direct" });
  assert.deepEqual(await connectionPath(request, runner), { path: "direct" });
  assert.equal(calls, 1);

  const failing = async () => {
    throw new Error("tailscale is not installed");
  };
  const other = { headers: { "x-forwarded-for": "100.118.42.48" }, socket: { remoteAddress: "127.0.0.1" } } as never;
  // The cached document still answers for another peer within the window.
  assert.deepEqual(await connectionPath(other, failing, true), { path: "relay", relay: "blr" });
  // No tailnet caller: nothing to ask.
  assert.deepEqual(await connectionPath({ headers: {}, socket: { remoteAddress: "127.0.0.1" } } as never, runner), { path: "unknown" });
});
