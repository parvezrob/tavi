// The one clock two caches share — the repos answer in `git.ts` and the `gh`
// pull-request LRU in `pull-request-cache.ts` — which is why it is its own
// file: either home would make the other's import a cycle, and both are at
// the 400-line limit. A wall clock steps backwards over a daylight change or
// an NTP correction, which would make a cached answer look newer than it is;
// `hrtime` only moves forward (#98).
export function monotonicNow(): number {
  return Number(process.hrtime.bigint() / 1_000_000n);
}
