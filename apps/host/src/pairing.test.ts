import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import {
  decodePairingPayload,
  DeviceRegistry,
  encodePairingPayload,
  fingerprintOf,
  PAIRING_SECRET_TTL_MILLISECONDS,
  PairingSessions,
} from "./pairing.js";
import { readStateFile } from "./state-file.js";

function scratch(): string {
  return mkdtempSync(path.join(tmpdir(), "tavi-pairing-"));
}

test("a paired phone's credential authorizes it and nothing else does", () => {
  const registry = new DeviceRegistry(scratch(), undefined, () => {});
  const { device, credential } = registry.add("Parvez's iPhone");

  assert.equal(registry.authorize(credential)?.id, device.id);
  assert.equal(registry.authorize(`${credential}x`), undefined);
  assert.equal(registry.authorize(""), undefined);
  assert.equal(registry.list().length, 1);
  assert.equal(registry.list()[0]?.name, "Parvez's iPhone");
});

test("credentials are stored only as hashes, owner-only", () => {
  const stateDir = scratch();
  const registry = new DeviceRegistry(stateDir, undefined, () => {});
  const { credential } = registry.add("phone");

  const file = path.join(stateDir, "devices.json");
  const raw = readFileSync(file, "utf8");
  assert.ok(!raw.includes(credential));
  assert.match(raw, /"credentialHash": "[0-9a-f]{64}"/);
  assert.equal(statSync(file).mode & 0o777, 0o600);
});

test("revoking one phone leaves the others paired", () => {
  const registry = new DeviceRegistry(scratch(), undefined, () => {});
  const first = registry.add("first");
  const second = registry.add("second");

  assert.equal(registry.revoke(first.device.id), true);
  assert.equal(registry.authorize(first.credential), undefined);
  assert.equal(registry.authorize(second.credential)?.name, "second");
  assert.equal(registry.revoke("second"), true);
  assert.equal(registry.revoke("nobody"), false);
  assert.deepEqual(registry.list(), []);
});

test("last-seen is recorded but not on every request", () => {
  let tick = 0;
  const registry = new DeviceRegistry(
    scratch(),
    () => new Date(1_700_000_000_000 + tick),
    () => {},
  );
  const { credential } = registry.add("phone");

  registry.authorize(credential);
  const first = registry.list()[0]?.lastSeenAt;
  assert.ok(first);
  tick = 10_000;
  registry.authorize(credential);
  assert.equal(registry.list()[0]?.lastSeenAt, first);
  tick = 70_000;
  registry.authorize(credential);
  assert.notEqual(registry.list()[0]?.lastSeenAt, first);
});

test("a minute of credential rechecks across five sockets reads the device list at most three times (#68)", () => {
  let tick = 0;
  let reads = 0;
  const registry = new DeviceRegistry(
    scratch(),
    () => new Date(tick),
    () => {},
    (file) => {
      reads += 1;
      return readStateFile(file);
    },
  );
  const { credential } = registry.add("phone");
  reads = 0;

  // Five phones holding a socket open, each re-checking its credential on the
  // host's 2 s clock: 150 checks, and the disk is asked once per 30 s window.
  for (tick = 0; tick <= 60_000; tick += 2_000) {
    for (let socket = 0; socket < 5; socket += 1) assert.ok(registry.authorize(credential));
  }
  assert.ok(reads <= 3, `the device list was read ${reads} times in a minute`);
});

test("a revoke this host makes reaches the next 2 s recheck, not the next disk window (#68)", () => {
  let tick = 0;
  const registry = new DeviceRegistry(
    scratch(),
    () => new Date(tick),
    () => {},
  );
  const { device, credential } = registry.add("phone");

  tick = 2_000;
  assert.ok(registry.authorize(credential));
  assert.equal(registry.revoke(device.id), true);
  tick = 4_000;
  assert.equal(registry.authorize(credential), undefined);
});

test("a device list another process rewrote is picked up at the next disk window (#68)", () => {
  const stateDir = scratch();
  let tick = 0;
  const registry = new DeviceRegistry(
    stateDir,
    () => new Date(tick),
    () => {},
  );
  const { credential } = registry.add("phone");
  assert.ok(registry.authorize(credential));

  // `tavi devices revoke` is its own process writing the same file.
  const cli = new DeviceRegistry(
    stateDir,
    () => new Date(tick),
    () => {},
  );
  assert.equal(cli.revoke(cli.list()[0]?.id ?? ""), true);

  tick = 29_000;
  assert.ok(registry.authorize(credential), "inside the window the list in memory is the answer");
  tick = 30_000;
  assert.equal(registry.authorize(credential), undefined, "the file's mtime moved, so it is read again");
});

test("an unreadable device list lets nobody in and says why", () => {
  const stateDir = scratch();
  const reported: string[] = [];
  let tick = 0;
  const registry = new DeviceRegistry(
    stateDir,
    () => new Date(tick),
    (message) => reported.push(message),
  );
  const { credential } = registry.add("phone");

  writeFileSync(path.join(stateDir, "devices.json"), "{ nope");
  // An edit no host process made is seen at the next disk window (#68 finding 1).
  tick = 30_000;
  assert.equal(registry.authorize(credential), undefined);
  assert.match(reported.at(-1) ?? "", /could not read the paired devices/);
});

test("the host identity is stable across reads and unique per host", () => {
  const stateDir = scratch();
  const registry = new DeviceRegistry(stateDir, undefined, () => {});
  const first = registry.identity().fingerprint;

  assert.match(first, /^[0-9A-F]{4} [0-9A-F]{4} · [0-9A-F]{4} [0-9A-F]{4}$/);
  assert.equal(new DeviceRegistry(stateDir, undefined, () => {}).identity().fingerprint, first);
  assert.notEqual(new DeviceRegistry(scratch(), undefined, () => {}).identity().fingerprint, first);
  assert.equal(fingerprintOf(Buffer.alloc(32, 1)), fingerprintOf(Buffer.alloc(32, 1)));
});

test("a pairing secret works exactly once and only while fresh", () => {
  let now = 1_000;
  const sessions = new PairingSessions(() => now);
  const { secret } = sessions.begin();

  assert.equal(sessions.redeem("wrong"), false);
  assert.equal(sessions.redeem(secret), true);
  assert.equal(sessions.redeem(secret), false);

  const { secret: stale } = sessions.begin();
  now += PAIRING_SECRET_TTL_MILLISECONDS + 1;
  assert.equal(sessions.redeem(stale), false);
  assert.equal(sessions.pendingCount, 0);
});

test("pairing codes cannot be minted without bound", () => {
  const sessions = new PairingSessions(() => 0);
  for (let index = 0; index < 5; index += 1) sessions.begin();
  assert.throws(() => sessions.begin(), /Too many pairing codes/);
});

test("the QR payload round-trips and rejects anything else", () => {
  const payload = {
    url: "https://studio-mac.tail1234.ts.net",
    secret: "abc_DEF-123",
    fingerprint: "8F2A 19C4 · 7B10 D6E9",
    hostName: "studio-mac",
  };
  const encoded = encodePairingPayload(payload);

  assert.ok(encoded.startsWith("tavi://pair?"));
  // Never "+" for a space: the phone's parser does not decode it (owner-hit
  // bug: the fingerprint arrived as "99F5+7AF0+·+E678+C534").
  assert.ok(!encoded.includes("+"), encoded);
  assert.ok(encoded.includes("f=8F2A%2019C4%20%C2%B7%207B10%20D6E9"), encoded);
  assert.deepEqual(decodePairingPayload(encoded), payload);
  assert.deepEqual(decodePairingPayload(`  ${encoded}\n`), payload);
  assert.equal(decodePairingPayload("https://example.com/pair?u=x&s=y&f=z"), undefined);
  assert.equal(decodePairingPayload("tavi://pair?u=https://h&s=&f=z"), undefined);
  assert.equal(decodePairingPayload("not a url"), undefined);
});
