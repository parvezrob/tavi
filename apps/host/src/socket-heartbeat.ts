import type { WebSocket } from "ws";
import { type ChaosClock, type ChaosTimerHandle, REAL_CLOCK } from "./chaos.js";

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
  clock?: Pick<ChaosClock, "setTimeout">;
  /** False while a blackhole holds this socket: it is neither pinged nor counted. */
  gate?: () => boolean;
  /** How a ping leaves. Injectable so a send that never completes is testable. */
  send?: (websocket: WebSocket, done: () => void) => void;
}

export function keepAlive(websocket: WebSocket, options: KeepAliveOptions = {}): void {
  const intervalMs = options.intervalMs ?? EVENTS_PING_INTERVAL_MILLISECONDS;
  const clock = options.clock ?? REAL_CLOCK;
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
    // phone's recovery, not the host's patience with a fault it injected. Only
    // the ping outstanding when the window opened is forgiven — the peer was
    // never given a chance to answer that one. Misses already counted stand,
    // or a fault on alternate ticks would keep a dead socket alive for ever.
    if (options.gate?.() === false) {
      unanswered = false;
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
    // and ws hands one that outlives the close an error nobody needs to hear.
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
}
