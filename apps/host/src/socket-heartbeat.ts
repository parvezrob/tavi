import type { WebSocket } from "ws";
import type { ChaosTimerHandle } from "./chaos.js";

// Server-side liveness for the events socket (#111, #68 finding 8). A phone
// whose network vanished with TCP still up answers nothing and reports
// nothing: without this the host keeps the socket, its herdr subscription and
// its credential recheck alive for hours. Terminal sockets are deliberately
// out — a terminate 30-45 s into a tunnel would hand the pane back at the
// desktop size and start retention early, for no measured gain.

export const EVENTS_PING_INTERVAL_MILLISECONDS = 15_000;
// Two, not one: a single interval's silence is a slow network, two is a peer
// that is gone. The wall time to terminate is therefore 30-45 s depending on
// where the last pong landed between ticks.
const MISSES_BEFORE_TERMINATE = 2;

export interface KeepAliveOptions {
  intervalMs?: number;
  /** The same clock chaos measures its windows on, so a test never waits 45 s. */
  clock?: { setTimeout(run: () => void, ms: number): ChaosTimerHandle };
  /** False while a blackhole holds this socket: it is neither pinged nor counted. */
  gate?: (websocket: WebSocket) => boolean;
  /** How a ping leaves. Injectable so a send that never completes is testable. */
  send?: (websocket: WebSocket, done: () => void) => void;
}

const REAL_TIMERS = {
  setTimeout: (run: () => void, ms: number): ChaosTimerHandle => {
    const timer = setTimeout(run, ms);
    timer.unref?.();
    return { cancel: () => clearTimeout(timer) };
  },
};

/**
 * Pings `websocket` every interval and terminates it after two unanswered
 * pings. Returns the stop the caller can use; `close` and `error` already
 * stop it themselves.
 */
export function keepAlive(websocket: WebSocket, options: KeepAliveOptions = {}): () => void {
  const intervalMs = options.intervalMs ?? EVENTS_PING_INTERVAL_MILLISECONDS;
  const clock = options.clock ?? REAL_TIMERS;
  const send = options.send ?? ((socket, done) => socket.ping(undefined, undefined, done));
  let timer: ChaosTimerHandle | undefined;
  let unanswered = false;
  let misses = 0;
  let stopped = false;

  const stop = (): void => {
    stopped = true;
    timer?.cancel();
    timer = undefined;
  };

  const arm = (): void => {
    if (!stopped) timer = clock.setTimeout(tick, intervalMs);
  };

  function tick(): void {
    timer = undefined;
    if (stopped) return;
    if (websocket.readyState !== websocket.OPEN) {
      stop();
      return;
    }
    // A blackholed socket is not asked and not counted: chaos is measuring the
    // phone's recovery, not the host's patience with a fault it injected.
    if (options.gate?.(websocket) === false) {
      arm();
      return;
    }
    if (unanswered) {
      misses += 1;
      if (misses >= MISSES_BEFORE_TERMINATE) {
        stop();
        websocket.terminate();
        return;
      }
    }
    unanswered = true;
    // The completion is a seam and nothing waits on it: a send that never
    // returns must not stop the next tick from counting this ping as missed,
    // and one that completes after the close must not throw.
    send(websocket, () => undefined);
    arm();
  }

  websocket.on("pong", () => {
    unanswered = false;
    misses = 0;
  });
  websocket.once("close", stop);
  websocket.once("error", stop);
  arm();
  return stop;
}
