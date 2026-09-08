import type { HerdrAgentsSnapshot } from "./herdr-events.js";
import type { HerdrAgentInfo } from "./types.js";

// The host's patience with a slow herdr (#111). Observed on the owner's
// phone: while the Mac was under load one herdr RPC missed its 2 s deadline,
// the feed published `available: false` with an empty list, and every
// project and agent of that computer disappeared from the home behind
// "Herdr did not respond in time." — while a second computer's stayed.
// Herdr answered the next call in 0.32 s. Nothing was broken; the host was
// impatient, and the phone faithfully rendered a total loss of state.
//
// So a failed refresh no longer erases anything. The last list herdr
// actually gave is held and kept on the wire — same `available: true`, same
// agents, plus `asOf`, the moment it was read — while the host retries.
// Only when herdr has said nothing for the whole grace period does the feed
// fall back to the honest "unavailable, no agents".
//
// The grace is sized off the RPC layer's own worst case: `listAgents` makes
// two sequential calls (`ping`, then `agent.list` + `tab.list` together) and
// each costs at most its 2 s timeout plus one 2 s retry (`herdr-rpc.ts`), so
// a refresh that fails outright takes up to 8 s, and the feed re-attempts
// ~2 s after that. Ten seconds therefore guarantees a second, independent
// attempt has begun before the host declares herdr gone — one bad moment can
// never do it — and is still short enough that a computer that really did go
// away is reported while the person is still looking at the screen.
export const HELD_SNAPSHOT_GRACE_MILLISECONDS = 10_000;

export class HeldSnapshot {
  private held: { agents: HerdrAgentInfo[]; asOf: number } | undefined;
  private failingSince: number | undefined;
  private holdingNow = false;

  constructor(
    private readonly graceMilliseconds: number = HELD_SNAPSHOT_GRACE_MILLISECONDS,
    private readonly now: () => number = Date.now,
  ) {}

  /** Whether what is on the wire right now is a held list rather than a fresh one. */
  get holding(): boolean {
    return this.holdingNow;
  }

  /** Herdr answered: this list is both the new truth and the new fallback. */
  remember(agents: HerdrAgentInfo[]): void {
    this.held = { agents, asOf: this.now() };
    this.failingSince = undefined;
    this.holdingNow = false;
  }

  // Herdr did not answer: what every phone should be told now. A host that
  // has no herdr at all — never installed, not running — has nothing to hold
  // and is reported unavailable at once, with herdr's own sentence, exactly
  // as before. `asOf` is the timestamp of the *held* list, not of this
  // moment, so re-serving it produces the identical frame and a hold costs
  // the phones one push however long it lasts.
  onFailure(reason: string): HerdrAgentsSnapshot {
    const now = this.now();
    this.failingSince ??= now;
    const held = this.held;
    if (!held || now - this.failingSince >= this.graceMilliseconds) {
      this.held = undefined;
      this.holdingNow = false;
      return { available: false, reason, agents: [] };
    }
    this.holdingNow = true;
    return { available: true, agents: held.agents, asOf: held.asOf };
  }
}
