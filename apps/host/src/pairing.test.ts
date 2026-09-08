import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, statSync, utimesSync, writeFileSync } from "node:fs";
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

const DEVICES_FILE = "devices.json";

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

// The disk seams, counted apart: a stat is the cheap thing every recheck may
// do, a read is the thing #68 finding 1 was about.
function countingRegistry(
  stateDir: string,
  clock: () => number,
  counts: { reads: number; stats: number },
  report: (message: string) => void = () => {},
  read: (file: string) => ReturnType<typeof readStateFile> = readStateFile,
): DeviceRegistry {
  return new DeviceRegistry(
    stateDir,
    () => new Date(clock()),
    report,
    (file) => {
      counts.reads += 1;
      return read(file);
    },
    (file) => {
      counts.stats += 1;
      try {
        const status = statSync(file);
        return `${status.mtimeMs}:${status.size}:${status.ino}`;
      } catch {
        return "";
      }
    },
  );
}

test("150 credential rechecks in a minute stat the file every time and read it three times (#68)", () => {
  let tick = 0;
  const counts = { reads: 0, stats: 0 };
  const registry = countingRegistry(scratch(), () => tick, counts);
  const { credential } = registry.add("phone");
  counts.reads = 0;
  counts.stats = 0;

  // Five phones holding a socket open, each re-checking on the host's 2 s
  // clock. Nothing moves the file, so the only reads are the 30 s floor at
  // 30 s and 60 s and the last-seen write the minute mark earns.
  for (tick = 0; tick <= 60_000; tick += 2_000) {
    for (let socket = 0; socket < 5; socket += 1) assert.ok(registry.authorize(credential));
  }
  assert.equal(counts.reads, 3, `the device list was read ${counts.reads} times in a minute of rechecks`);
  assert.ok(counts.stats >= 150, `only ${counts.stats} stats for 155 rechecks — a check that skips the file is stale`);
});

test("a revoke this host makes is dead at the next recheck without re-reading the file (#68)", () => {
  let tick = 0;
  const counts = { reads: 0, stats: 0 };
  const registry = countingRegistry(scratch(), () => tick, counts);
  const { device, credential } = registry.add("phone");

  tick = 2_000;
  assert.ok(registry.authorize(credential));
  assert.equal(registry.revoke(device.id), true);
  counts.reads = 0;
  tick = 4_000;
  assert.equal(registry.authorize(credential), undefined);
  // The host wrote the file, so it already knows what is in it.
  assert.equal(counts.reads, 0, "this host's own write should not need reading back");
});

test("a revoke another process made cuts every live socket off within one 2 s recheck (#68)", () => {
  const stateDir = scratch();
  let tick = 0;
  const registry = new DeviceRegistry(
    stateDir,
    () => new Date(tick),
    () => {},
  );
  const { credential } = registry.add("phone");

  // Two sockets whose 2 s rechecks are offset from each other, so the revoke
  // lands between them and neither may be more than its own interval late.
  tick = 1_000;
  assert.ok(registry.authorize(credential), "socket A");
  tick = 2_000;
  assert.ok(registry.authorize(credential), "socket B");

  // `tavi devices revoke` is its own process writing the same file, and the
  // promise in protocol/README.md is that it takes effect immediately.
  const cli = new DeviceRegistry(
    stateDir,
    () => new Date(tick),
    () => {},
  );
  tick = 2_500;
  assert.equal(cli.revoke(cli.list()[0]?.id ?? ""), true);

  tick = 3_000;
  assert.equal(registry.authorize(credential), undefined, "socket A, one interval after the revoke");
  tick = 4_000;
  assert.equal(registry.authorize(credential), undefined, "socket B, one interval after the revoke");
});

test("a write this host makes is built on the file, so another process's changes are never undone (#68)", () => {
  const stateDir = scratch();
  let tick = 0;
  // A filesystem that offers no change signal at all — the worst case the
  // 30 s floor exists for. Inside that window a *read* may legitimately serve
  // the list it has; a *write* may never merge onto it, or it writes back a
  // device another process revoked and that credential is alive for good.
  const blind = (dir: string) =>
    new DeviceRegistry(
      dir,
      () => new Date(tick),
      () => {},
      readStateFile,
      () => "unchanging",
    );
  const registry = blind(stateDir);
  const { device, credential } = registry.add("first");
  assert.ok(registry.authorize(credential), "warms the cache this write must not be built on");

  const other = new DeviceRegistry(
    stateDir,
    () => new Date(tick),
    () => {},
  );
  assert.equal(other.revoke(device.id), true);
  const kept = other.add("second");

  tick = 1_000;
  registry.add("third");
  assert.deepEqual(
    other
      .list()
      .map((entry) => entry.name)
      .sort(),
    ["second", "third"],
    "the file on disk is what the next process reads",
  );
  assert.equal(registry.authorize(credential), undefined, "the revoked credential must stay revoked");
  assert.ok(other.authorize(kept.credential), "the other process's phone must survive");
});

test("a read that fails once is not cached: the next recheck tries again (#68)", () => {
  const stateDir = scratch();
  let tick = 0;
  const counts = { reads: 0, stats: 0 };
  let failNext = false;
  const registry = countingRegistry(
    stateDir,
    () => tick,
    counts,
    () => {},
    (file) => {
      if (!failNext) return readStateFile(file);
      failNext = false;
      return { status: "unreadable", reason: "EIO" };
    },
  );
  const { credential } = registry.add("phone");

  // A transient disk error, with the file itself untouched — so nothing about
  // it will ever look different again.
  tick = 30_000;
  failNext = true;
  assert.equal(registry.authorize(credential), undefined, "a phone cannot be let in on an unreadable list");
  tick = 32_000;
  assert.ok(registry.authorize(credential), "the failure must not have been cached");
});

test("two writes the filesystem stamps with one mtime are both seen (#68)", () => {
  const stateDir = scratch();
  const file = path.join(stateDir, DEVICES_FILE);
  let tick = 0;
  const registry = new DeviceRegistry(
    stateDir,
    () => new Date(tick),
    () => {},
  );
  const { credential } = registry.add("phone");

  // A filesystem with a coarse clock stamps two writes in the same tick
  // identically. Forcing the stamp is how that becomes a test rather than a
  // hope: after this, mtime carries no signal at all between the two writes.
  const stamp = new Date(1_700_000_000_000);
  utimesSync(file, stamp, stamp);
  assert.ok(registry.authorize(credential), "reads and remembers the file under the fixed stamp");

  const other = new DeviceRegistry(
    stateDir,
    () => new Date(tick),
    () => {},
  );
  assert.equal(other.revoke(other.list()[0]?.id ?? ""), true);
  utimesSync(file, stamp, stamp);
  assert.equal(statSync(file).mtimeMs, stamp.getTime(), "the two writes really do share an mtime");

  tick = 1;
  assert.equal(registry.authorize(credential), undefined, "size and inode are what is left to notice by");
});

test("an unreadable device list lets nobody in and says why", () => {
  const stateDir = scratch();
  const reported: string[] = [];
  const registry = new DeviceRegistry(stateDir, undefined, (message) => reported.push(message));
  const { credential } = registry.add("phone");

  writeFileSync(path.join(stateDir, "devices.json"), "{ nope");
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
