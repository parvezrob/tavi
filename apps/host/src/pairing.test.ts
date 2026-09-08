import assert from "node:assert/strict";
import { mkdtempSync, readdirSync, readFileSync, statSync, utimesSync, writeFileSync } from "node:fs";
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
import { readStateFile, writeStateFile } from "./state-file.js";

const DEVICES_FILE = "devices.json";

function scratch(): string {
  return mkdtempSync(path.join(tmpdir(), "tavi-pairing-"));
}

// The registry's own default signature, so a test that injects the stat seam
// still answers what an uninjected one would everywhere it is not interfering.
function fileSignature(file: string): string {
  try {
    const status = statSync(file);
    return `${status.mtimeMs}:${status.size}:${status.ino}`;
  } catch {
    return "";
  }
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

test("last-seen never touches the device list: current in memory, its own file at most once a minute (#68)", () => {
  const stateDir = scratch();
  let tick = 0;
  const registry = new DeviceRegistry(
    stateDir,
    () => new Date(1_700_000_000_000 + tick),
    () => {},
  );
  const { device, credential } = registry.add("phone");
  const devices = path.join(stateDir, DEVICES_FILE);
  const written = readFileSync(devices, "utf8");
  const onDisk = () => {
    const seen = readFileSync(path.join(stateDir, "devices-seen.json"), "utf8");
    return (JSON.parse(seen) as { seen: Record<string, string> }).seen[device.id];
  };

  registry.authorize(credential);
  const first = registry.list()[0]?.lastSeenAt;
  assert.ok(first);
  assert.equal(onDisk(), first);

  // What a person is shown is always current; the disk is what is rationed.
  tick = 10_000;
  registry.authorize(credential);
  assert.notEqual(registry.list()[0]?.lastSeenAt, first);
  assert.equal(onDisk(), first, "ten seconds in, the file has not been rewritten");

  tick = 70_000;
  registry.authorize(credential);
  assert.notEqual(onDisk(), first);

  // The point of the move: nothing a phone does on the authorize path rewrites
  // the file that decides who gets in.
  assert.equal(readFileSync(devices, "utf8"), written, "devices.json must be byte-identical after all of that");
  assert.ok(!written.includes("lastSeenAt"), "and it never held a last-seen stamp at all");
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
  // clock. Nothing moves the file, so all three reads are structural: the
  // first check after `add` dropped the cache, then the 30 s floor at 30 s and
  // at 60 s. The last-seen write the minute mark earns goes to another file
  // entirely and costs this one nothing.
  for (tick = 0; tick <= 60_000; tick += 2_000) {
    for (let socket = 0; socket < 5; socket += 1) assert.ok(registry.authorize(credential));
  }
  assert.equal(counts.reads, 3, `the device list was read ${counts.reads} times in a minute of rechecks`);
  assert.ok(counts.stats >= 150, `only ${counts.stats} stats for 155 rechecks — a check that skips the file is stale`);
});

test("a revoke this host makes is dead at the very next recheck (#68)", () => {
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
  // Exactly one: writing drops the cache rather than replacing it, so the
  // check after a write pays a read and every check after that does not.
  assert.equal(counts.reads, 1, "one re-read after a write, then memory again");
  tick = 6_000;
  assert.equal(registry.authorize(credential), undefined);
  assert.equal(counts.reads, 1);
});

test("a foreign write landing in the window of this host's own write is not hidden by it (#68)", () => {
  const stateDir = scratch();
  let tick = 0;
  // A signature that never changes: the worst case, and the one that makes
  // caching a just-written list indistinguishable from caching a stale one.
  const blind = new DeviceRegistry(
    stateDir,
    () => new Date(tick),
    () => {},
    readStateFile,
    () => "unchanging",
  );
  const { device, credential } = blind.add("first");

  // Another process rewrites the file in the same window this host wrote it.
  const other = new DeviceRegistry(
    stateDir,
    () => new Date(tick),
    () => {},
  );
  assert.equal(other.revoke(device.id), true);

  tick = 1;
  assert.equal(blind.authorize(credential), undefined, "the write must not have cached this host's own list over it");
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

test("a revoke that lands between a write's read and its rename keeps the credential dead (#68)", () => {
  const stateDir = scratch();
  const devices = path.join(stateDir, DEVICES_FILE);
  const tick = 0;
  const registry = new DeviceRegistry(
    stateDir,
    () => new Date(tick),
    () => {},
  );
  const revoked = registry.add("revoked");
  registry.add("kept");

  // The interleaving a lock was supposed to prevent and could not: this
  // writer has already read [revoked, kept] and computed [revoked, kept,
  // added] when another process revokes. Its stat is the seam — the second
  // one it makes is the check `writeStateFile` runs immediately before the
  // rename, so a foreign write performed there lands exactly between the read
  // this write was computed from and the swap that would resurrect it.
  let stats = 0;
  let interleaved = false;
  const writer = new DeviceRegistry(
    stateDir,
    () => new Date(tick),
    () => {},
    readStateFile,
    (file) => {
      stats += 1;
      if (file === devices && stats === 2) {
        interleaved = true;
        assert.equal(registry.revoke(revoked.device.id), true, "the foreign revoke must itself land");
      }
      return fileSignature(file);
    },
  );
  writer.add("added");

  assert.ok(interleaved, "the test must actually have revoked between the read and the rename");
  assert.equal(
    new DeviceRegistry(
      stateDir,
      () => new Date(tick),
      () => {},
    ).authorize(revoked.credential),
    undefined,
    "the revoked credential must stay revoked, however the write that raced it finished",
  );
  assert.deepEqual(
    writer
      .list()
      .map((entry) => entry.name)
      .sort(),
    ["added", "kept"],
    "and the retry rebuilds on the file the revoke left, so both intents survive",
  );
});

test("a write that keeps losing the race gives up with an error instead of looping (#68)", () => {
  const stateDir = scratch();
  const devices = path.join(stateDir, DEVICES_FILE);
  const tick = 0;
  const registry = new DeviceRegistry(
    stateDir,
    () => new Date(tick),
    () => {},
  );
  const { credential } = registry.add("phone");
  const before = readFileSync(devices, "utf8");

  // A file that moves under every single attempt. Three of those is a
  // permanent failure, not a reason to keep trying.
  let swaps = 0;
  const loser = new DeviceRegistry(
    stateDir,
    () => new Date(tick),
    () => {},
    readStateFile,
    (file) => {
      if (file === devices && swaps < 100) {
        swaps += 1;
        writeStateFile(devices, JSON.parse(readFileSync(devices, "utf8")) as unknown);
      }
      return fileSignature(file);
    },
  );

  assert.throws(() => loser.add("never lands"), /another process changed it during each of 3 attempts/);
  assert.ok(swaps < 100, "it stopped on its own rather than being stopped by the counter");
  assert.deepEqual(
    registry.list().map((entry) => entry.name),
    ["phone"],
    "and wrote nothing: the list is the one the winners left",
  );
  assert.ok(registry.authorize(credential), "the phone nobody touched must survive a write that gave up");
  assert.equal(readFileSync(devices, "utf8"), before, "byte for byte the file it started from");
});

test("no lock file is taken, waited on or left behind, and a stale one from an older Tavi stops nothing (#68)", () => {
  const stateDir = scratch();
  const devices = path.join(stateDir, DEVICES_FILE);
  const tick = 0;
  const registry = new DeviceRegistry(
    stateDir,
    () => new Date(tick),
    () => {},
  );
  const first = registry.add("first");
  const second = registry.add("second");

  // Exactly what an older Tavi holding the lock looked like: fresh, so the
  // stale takeover would not have fired, and owned by a pid that is not ours.
  // A host that still waited for this would stall every mutation for seconds
  // and then refuse; this one must not notice it at all.
  writeFileSync(`${devices}.lock`, `999999 ${Date.now()}\n`, "utf8");

  const startedAt = Date.now();
  assert.equal(registry.revoke(first.device.id), true, "a revoke must not wait for anyone's lock");
  registry.add("third");
  assert.equal(registry.authorize(first.credential), undefined);
  assert.ok(registry.authorize(second.credential));
  assert.equal(registry.list().length, 2);
  const elapsed = Date.now() - startedAt;
  assert.ok(elapsed < 1_000, `waited ${elapsed} ms — something is still sleeping on a lock`);

  // And nothing of our own was created beside the list: no lock to leak, and
  // no temporary file left over from an abandoned swap.
  assert.deepEqual(
    readdirSync(stateDir)
      .filter((name) => name !== DEVICES_FILE && name !== `${DEVICES_FILE}.lock`)
      .sort(),
    [],
    "a mutation leaves nothing beside devices.json",
  );
});

test("authorize and list never write the device list and never wait on one (#68)", () => {
  const stateDir = scratch();
  const devices = path.join(stateDir, DEVICES_FILE);
  let tick = 0;
  const registry = new DeviceRegistry(
    stateDir,
    () => new Date(tick),
    () => {},
  );
  const { credential } = registry.add("phone");
  const before = fileSignature(devices);

  // The 2 s credential recheck, a few hundred times over, plus the listing a
  // person asks for. Read paths were never writers and must never become
  // them, whatever the state of the directory around them.
  writeFileSync(`${devices}.lock`, `999999 ${Date.now()}\n`, "utf8");
  const startedAt = Date.now();
  for (let i = 0; i < 300; i += 1) {
    tick += 2_000;
    assert.ok(registry.authorize(credential));
    assert.equal(registry.list().length, 1);
  }
  const elapsed = Date.now() - startedAt;

  assert.equal(fileSignature(devices), before, "not one read path wrote the file that decides access");
  assert.ok(elapsed < 1_000, `600 reads took ${elapsed} ms — a read is blocking on something`);
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
