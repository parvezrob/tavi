import assert from "node:assert/strict";
import test from "node:test";
import type { IPty } from "node-pty";
import type { RawData, WebSocket } from "ws";
import { AttachmentStore } from "./attachment.js";
import { bridgeTerminalV2, type TerminalTarget } from "./terminal-bridge.js";
import type { ServerTerminalMessage } from "./types.js";

const TAKEOVER: ServerTerminalMessage = {
  type: "error",
  message: "Another connection took over this terminal.",
  code: "superseded",
};

// A frame the phone sent before the takeover's close reached it arrives at the
// bridge after the handover. These tests drive that ordering directly instead
// of racing a real socket against a real close.
class FakeSocket {
  readonly OPEN = 1;
  readonly closes: Array<{ code: number; reason: string }> = [];
  readonly controls: ServerTerminalMessage[] = [];
  readonly outputs: Buffer[] = [];
  bufferedAmount = 0;
  readyState = 1;

  private readonly closeListeners: Array<() => void> = [];
  private readonly messageListeners: Array<(raw: RawData, isBinary: boolean) => void> = [];

  get asWebSocket(): WebSocket {
    return this as unknown as WebSocket;
  }

  on(event: string, listener: (raw: RawData, isBinary: boolean) => void): this {
    if (event === "message") this.messageListeners.push(listener);
    return this;
  }

  once(event: string, listener: () => void): this {
    if (event === "close") this.closeListeners.push(listener);
    return this;
  }

  send(data: string | Buffer): void {
    if (typeof data === "string") this.controls.push(JSON.parse(data) as ServerTerminalMessage);
    else this.outputs.push(data);
  }

  close(code: number, reason: string): void {
    this.closes.push({ code, reason });
    this.readyState = 2;
  }

  deliver(message: Record<string, unknown>): void {
    for (const listener of this.messageListeners) listener(Buffer.from(JSON.stringify(message)), false);
  }

  emitClose(): void {
    assert.ok(this.closeListeners.length > 0, "the bridge registered no close listener");
    for (const listener of this.closeListeners) listener();
  }
}

class FakePty {
  readonly resizes: Array<{ cols: number; rows: number }> = [];
  readonly writes: string[] = [];
  killed = false;

  readonly pty = {
    onData: (listener: (data: string) => void) => {
      this.emitData = listener;
      return { dispose: () => {} };
    },
    onExit: () => ({ dispose: () => {} }),
    resize: (cols: number, rows: number) => {
      this.resizes.push({ cols, rows });
    },
    write: (data: string) => {
      this.writes.push(data);
    },
    kill: () => {
      this.killed = true;
    },
  } as unknown as IPty;

  emitData: (data: string) => void = () => {};
}

function terminalTarget(ptys: FakePty[]): TerminalTarget {
  return {
    key: "fixture",
    spawn: () => {
      const terminal = new FakePty();
      ptys.push(terminal);
      return terminal.pty;
    },
  };
}

function readyMessage(socket: FakeSocket): { stream?: string; offset?: number; resumed?: boolean } {
  const ready = socket.controls[0];
  assert.equal(ready?.type, "ready");
  if (ready?.type !== "ready") throw new Error("unreachable");
  return ready;
}

test("a fresh replacement tells the losing client it was superseded and stops serving it", (t) => {
  const store = new AttachmentStore({ retentionMs: 60_000 });
  t.after(() => store.disposeAll());
  const ptys: FakePty[] = [];
  const target = terminalTarget(ptys);

  const first = new FakeSocket();
  bridgeTerminalV2(first.asWebSocket, target, store);
  first.deliver({ type: "input", data: "mine\r" });
  assert.deepEqual(ptys[0]?.writes, ["mine\r"]);

  // No resume parameters at all: the fresh-attach branch, not the resume hit.
  const second = new FakeSocket();
  bridgeTerminalV2(second.asWebSocket, target, store);

  assert.deepEqual(first.controls.slice(1), [TAKEOVER]);
  assert.deepEqual(first.closes, [{ code: 1000, reason: "superseded" }]);

  first.deliver({ type: "input", data: "stale\r" });
  first.deliver({ type: "resize", cols: 40, rows: 10 });
  first.deliver({ type: "ping", id: "late" });
  assert.deepEqual(first.controls.slice(1), [TAKEOVER]);
  assert.deepEqual(ptys[0]?.writes, ["mine\r"]);
  assert.deepEqual(ptys[0]?.resizes, []);
  assert.deepEqual(ptys[1]?.writes, []);

  // Only the losing client's temporary attach pty is killed; the new one owns
  // a live attach to the same durable herdr pane.
  assert.equal(ptys.length, 2);
  assert.equal(ptys[0]?.killed, true);
  assert.equal(ptys[1]?.killed, false);

  // The new client is usable in both directions.
  second.deliver({ type: "input", data: "theirs\r" });
  second.deliver({ type: "ping", id: "beat" });
  assert.deepEqual(ptys[1]?.writes, ["theirs\r"]);
  assert.deepEqual(second.controls.at(-1), { type: "pong", id: "beat" });
  ptys[1]?.emitData("live output");
  assert.equal(second.outputs.length, 1);
});

test("a matching resume takes the attachment over without the old client reaching the new one's pty", (t) => {
  const store = new AttachmentStore({ retentionMs: 60_000 });
  t.after(() => store.disposeAll());
  const ptys: FakePty[] = [];
  const target = terminalTarget(ptys);

  const first = new FakeSocket();
  bridgeTerminalV2(first.asWebSocket, target, store);
  const stream = readyMessage(first).stream;
  assert.ok(stream);
  ptys[0]?.emitData("shared");

  const second = new FakeSocket();
  bridgeTerminalV2(second.asWebSocket, target, store, { stream, offset: 0 });
  const resumedReady = readyMessage(second);
  assert.equal(resumedReady.resumed, true);
  assert.equal(resumedReady.stream, stream);

  assert.deepEqual(first.controls.slice(1), [TAKEOVER]);
  assert.deepEqual(first.closes, [{ code: 1000, reason: "superseded" }]);

  // The pty is shared here, so a stale frame would land in the new owner's
  // terminal: input, resize and ping all stop at the losing connection.
  first.deliver({ type: "input", data: "stale\r" });
  first.deliver({ type: "resize", cols: 40, rows: 10 });
  first.deliver({ type: "ping", id: "late" });
  assert.deepEqual(first.controls.slice(1), [TAKEOVER]);
  assert.deepEqual(ptys[0]?.writes, []);
  assert.deepEqual(ptys[0]?.resizes, []);

  // A resume hit keeps the attachment: one pty, still alive, still the new
  // client's to drive.
  assert.equal(ptys.length, 1);
  assert.equal(ptys[0]?.killed, false);
  second.deliver({ type: "input", data: "theirs\r" });
  second.deliver({ type: "resize", cols: 100, rows: 40 });
  assert.deepEqual(ptys[0]?.writes, ["theirs\r"]);
  assert.deepEqual(ptys[0]?.resizes, [{ cols: 100, rows: 40 }]);
});

test("a fresh attach that cannot spawn leaves the current client in charge", (t) => {
  const store = new AttachmentStore({ retentionMs: 60_000 });
  t.after(() => store.disposeAll());
  const ptys: FakePty[] = [];
  const target = terminalTarget(ptys);

  const first = new FakeSocket();
  bridgeTerminalV2(first.asWebSocket, target, store);

  const unspawnable: TerminalTarget = {
    ...target,
    spawn: () => {
      throw new Error("herdr is not installed.");
    },
  };
  const second = new FakeSocket();
  assert.throws(() => bridgeTerminalV2(second.asWebSocket, unspawnable, store), /herdr is not installed/);

  // Nobody took the terminal, so nobody is told they lost it; the caller
  // reports the failure to the connection that could not be served.
  assert.deepEqual(first.controls.slice(1), []);
  assert.deepEqual(first.closes, []);
  assert.equal(ptys.length, 1);
  assert.equal(ptys[0]?.killed, false);
  assert.equal(store.get("fixture")?.isDisposed, false);

  first.deliver({ type: "input", data: "still mine\r" });
  first.deliver({ type: "ping", id: "beat" });
  assert.deepEqual(ptys[0]?.writes, ["still mine\r"]);
  assert.deepEqual(first.controls.at(-1), { type: "pong", id: "beat" });
  ptys[0]?.emitData("live output");
  assert.equal(first.outputs.length, 1);
});

test("an ordinary error frame carries no ownership code", (t) => {
  const store = new AttachmentStore({ retentionMs: 60_000 });
  t.after(() => store.disposeAll());
  const socket = new FakeSocket();
  bridgeTerminalV2(socket.asWebSocket, terminalTarget([]), store);

  socket.deliver({ type: "not a terminal message" });

  assert.deepEqual(socket.controls.at(-1), { type: "error", message: "Invalid terminal message." });
});

test("a losing client's late close cannot evict the client that replaced it", (t) => {
  const store = new AttachmentStore({ retentionMs: 60_000 });
  t.after(() => store.disposeAll());
  const ptys: FakePty[] = [];
  const target = terminalTarget(ptys);

  const first = new FakeSocket();
  bridgeTerminalV2(first.asWebSocket, target, store);
  const stream = readyMessage(first).stream;
  assert.ok(stream);

  const second = new FakeSocket();
  bridgeTerminalV2(second.asWebSocket, target, store, { stream, offset: 0 });

  // The old socket's close event arrives after the handover.
  first.emitClose();

  // The attachment still belongs to the second client: its output flows and
  // no retention or hand-back was started under it.
  ptys[0]?.emitData("still mine");
  assert.equal(second.outputs.length, 1);
  second.deliver({ type: "input", data: "after\r" });
  assert.deepEqual(ptys[0]?.writes, ["after\r"]);
  assert.equal(store.get("fixture")?.isDisposed, false);
});
