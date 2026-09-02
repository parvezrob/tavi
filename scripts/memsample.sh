#!/bin/zsh
# Samples the simulator Tavi app's memory while TaviMemoryChecks runs, and
# answers its `leaks` requests.
#
#   scripts/memsample.sh <log> <syncdir> [interval-seconds]
#
# Every interval: one line `<ts> pid=<pid> footprint=<MB> rssKB=<kB>` for the
# app process (phys footprint is the number iOS judges apps by). When the test
# drops `<syncdir>/leaks-<label>` it runs `leaks` on the app, writes the full
# report next to the log, appends the summary line, and removes the marker.
set -u
LOG=${1:?log file}
SYNC=${2:?sync dir}
EVERY=${3:-15}
mkdir -p "$SYNC"
log() { print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG" }
log "sampler start every=${EVERY}s"
while true; do
  pid=$(pgrep -x Tavi | head -1)
  if [[ -n $pid ]]; then
    fp=$(footprint -p "$pid" 2>/dev/null | sed -n 's/.*Footprint: \([0-9.]* [KMG]B\).*/\1/p' | head -1)
    rss=$(ps -o rss= -p "$pid" | tr -d ' ')
    log "sample pid=$pid footprint=${fp:-?} rssKB=${rss:-?}"
    for marker in "$SYNC"/leaks-*(N); do
      name=${marker:t}
      label=${name#leaks-}
      report="${LOG:r}.leaks-${label}.txt"
      leaks "$pid" > "$report" 2>&1
      summary=$(grep -m1 -E '^Process [0-9]+: [0-9]+ leaks? for' "$report" || tail -1 "$report")
      log "leaks label=$label $summary"
      # Retained-object counts that a leak of ours would show up in (leaks
      # itself only sees unreachable blocks). Directory count must be one
      # per paired computer; sockets one per directory (+1 while a terminal
      # is open). Network.framework since #70: nw_connection is the socket,
      # __NSURLSessionWebSocketTask must stay 0.
      heapfile="${LOG:r}.heap-${label}.txt"
      heap "$pid" > "$heapfile" 2>&1
      counts=$(grep -E '\s(AgentDirectory|__NSURLSessionWebSocketTask|NetworkWebSocketTask|NWConcrete_nw_connection|TerminalSessionController|GhosttyTerminalSurfaceView|SecCertificate)\s' "$heapfile" | awk '{print $4"="$1}' | tr '\n' ' ')
      log "heap label=$label $counts"
      rm -f "$marker"
    done
  else
    log "sample no Tavi process"
  fi
  sleep "$EVERY"
done
