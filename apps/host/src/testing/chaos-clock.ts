import type { ChaosClock, ChaosTimerHandle } from "../chaos.js";

// The clock the chaos suites hand `createChaos`, so a 30 s window is a call
// rather than a wait (AGENTS.md, the fault-injection rule). It starts at a
// plausible epoch because the routes report `at` as one.
export class ChaosTestClock implements ChaosClock {
  private current = Date.parse("2026-09-06T12:00:00Z");
  private pending: Array<{ at: number; run: () => void }> = [];

  now(): number {
    return this.current;
  }

  setTimeout(run: () => void, ms: number): ChaosTimerHandle {
    const entry = { at: this.current + ms, run };
    this.pending.push(entry);
    return {
      cancel: () => {
        this.pending = this.pending.filter((candidate) => candidate !== entry);
      },
    };
  }

  /** Moves time on and runs whatever came due, earliest first. */
  advance(ms: number): void {
    this.current += ms;
    for (;;) {
      const due = this.pending.filter((entry) => entry.at <= this.current).sort((left, right) => left.at - right.at)[0];
      if (!due) return;
      this.pending = this.pending.filter((entry) => entry !== due);
      due.run();
    }
  }
}
