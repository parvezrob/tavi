import assert from "node:assert/strict";
import test from "node:test";
import { chaosStartup, createChaos } from "./chaos.js";
import { ChaosTestClock } from "./testing/chaos-clock.js";

const DEVELOPER = { production: false, managed: false, ephemeral: false };

test("chaos is off unless TAVI_CHAOS says on", () => {
  assert.deepEqual(chaosStartup(undefined, DEVELOPER), { ok: true, enabled: false });
  assert.deepEqual(chaosStartup("", DEVELOPER), { ok: true, enabled: false });
  assert.deepEqual(chaosStartup("on", DEVELOPER), { ok: true, enabled: true });
});

test("chaos refuses anywhere a fault would reach someone who did not ask for one", () => {
  // Each of these is an exit 2 in index.ts; the sentence is what reaches stderr.
  for (const [value, runtime] of [
    ["yes", DEVELOPER],
    ["ON", DEVELOPER],
    ["1", DEVELOPER],
    ["on", { ...DEVELOPER, production: true }],
    ["on", { ...DEVELOPER, managed: true }],
    ["on", { ...DEVELOPER, ephemeral: true }],
  ] as const) {
    const decision = chaosStartup(value, runtime);
    assert.equal(decision.ok, false, `${value} in ${JSON.stringify(runtime)} should be refused`);
    if (decision.ok) throw new Error("unreachable");
    assert.match(decision.error, /TAVI_CHAOS/);
  }
});

test("a fault with nothing to target is a 404, and records nothing", () => {
  const chaos = createChaos();
  assert.deepEqual(chaos.fault({ kind: "terminate", socket: "events" }), {
    ok: false,
    status: 404,
    error: "No socket to fault.",
  });
  assert.deepEqual(chaos.fault({ kind: "terminate", socket: "terminal", paneId: "wB:p1" }), {
    ok: false,
    status: 404,
    error: "No socket to fault.",
  });
  assert.deepEqual(chaos.events(), []);

  // A refused fault must not consume an id either, or the soak's first real
  // fault would come back as `chaos-3`.
  const landed = chaos.fault({ kind: "hostPause", socket: "events", ms: 1_000 });
  assert.equal(landed.ok && landed.event.id, "chaos-1");
});

test("hostPause needs no socket and ends on its own clock", () => {
  const clock = new ChaosTestClock();
  const chaos = createChaos(clock);
  assert.equal(chaos.hostPaused(), false);

  const outcome = chaos.fault({ kind: "hostPause", socket: "events", ms: 30_000 });
  assert.equal(outcome.ok, true);
  assert.equal(chaos.hostPaused(), true);
  clock.advance(29_999);
  assert.equal(chaos.hostPaused(), true);
  clock.advance(1);
  assert.equal(chaos.hostPaused(), false);
  assert.deepEqual(
    chaos.events().map((event) => event.kind),
    ["hostPause"],
  );
});
