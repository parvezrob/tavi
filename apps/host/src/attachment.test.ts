import assert from "node:assert/strict";
import test from "node:test";
import { TerminalAttachment, AttachmentStore, type TerminalProcessLike } from "./attachment.js";

class FakeProcess implements TerminalProcessLike {
  readonly writes: string[] = [];
  readonly resizes: Array<{ cols: number; rows: number }> = [];
  killed = false;
  private dataListener: (data: string) => void = () => {};
  private exitListener: (event: { exitCode: number; signal?: number }) => void = () => {};

  write(data: string): void {
    this.writes.push(data);
  }

  resize(cols: number, rows: number): void {
    this.resizes.push({ cols, rows });
  }

  kill(): void {
    this.killed = true;
  }

  onData(callback: (data: string) => void): void {
    this.dataListener = callback;
  }

  onExit(callback: (event: { exitCode: number; signal?: number }) => void): void {
    this.exitListener = callback;
  }

  emitData(data: string): void {
    this.dataListener(data);
  }

  emitExit(exitCode: number, signal?: number): void {
    this.exitListener({ exitCode, ...(signal === undefined ? {} : { signal }) });
  }
}

function makeClient() {
  return {
    outputs: 0,
    exits: [] as Array<{ code: number; signal?: number }>,
    superseded: 0,
    onOutput() {
      this.outputs += 1;
    },
    onExit(exit: { code: number; signal?: number }) {
      this.exits.push(exit);
    },
    onSuperseded() {
      this.superseded += 1;
    },
  };
}

test("ring buffer tracks absolute offsets across trimming", () => {
  const process = new FakeProcess();
  const attachment = new TerminalAttachment(process, { maxBufferBytes: 10, retentionMs: 60_000 });

  process.emitData("abcde");
  process.emitData("fghij");
  assert.equal(attachment.startOffset, 0);
  assert.equal(attachment.endOffset, 10);
  assert.equal(attachment.read(2, 100)?.toString(), "cdefghij");
  assert.equal(attachment.read(3, 4)?.toString(), "defg");

  process.emitData("klmno");
  assert.equal(attachment.endOffset, 15);
  assert.equal(attachment.startOffset, 5);
  assert.ok(attachment.contains(5));
  assert.ok(!attachment.contains(4));
  assert.equal(attachment.read(4, 100), undefined);
  assert.equal(attachment.read(5, 100)?.toString(), "fghijklmno");
  assert.equal(attachment.read(15, 100)?.length, 0);

  attachment.dispose();
});

test("claim delivers live output, supersedes the previous client, and release restarts retention", async () => {
  const process = new FakeProcess();
  const attachment = new TerminalAttachment(process, { retentionMs: 30 });

  const first = makeClient();
  attachment.claim(first);
  process.emitData("one");
  assert.equal(first.outputs, 1);

  const second = makeClient();
  attachment.claim(second);
  assert.equal(first.superseded, 1);
  process.emitData("two");
  assert.equal(first.outputs, 1);
  assert.equal(second.outputs, 1);

  // A claimed attachment must survive well past the retention window.
  await new Promise((resolve) => setTimeout(resolve, 60));
  assert.ok(!attachment.isDisposed);

  const resizesBeforeRelease = process.resizes.length;
  attachment.release(second);
  // With no way to ask what the desktop shows, releasing leaves the size
  // alone — an oversized guess would crop the Mac's view (#44).
  assert.equal(process.resizes.length, resizesBeforeRelease);
  await new Promise((resolve) => setTimeout(resolve, 60));
  assert.ok(attachment.isDisposed);
  assert.ok(process.killed);
});

test("release hands a herdr pane back to the desktop's own size (#44)", async () => {
  const process = new FakeProcess();
  const attachment = new TerminalAttachment(process, {
    retentionMs: 60_000,
    detachGraceMs: 1,
    detachedSize: async () => ({ cols: 174, rows: 49 }),
  });
  const phone = makeClient();
  attachment.claim(phone);
  attachment.resize(44, 22);

  attachment.release(phone);
  await new Promise((resolve) => setTimeout(resolve, 15));
  // herdr keeps whatever size it is told, so the desktop's own rect is the
  // only honest size to hand back.
  assert.deepEqual(process.resizes.at(-1), { cols: 174, rows: 49 });
  attachment.dispose();
});

test("release leaves the size alone when the desktop size is unknown", async () => {
  const process = new FakeProcess();
  const attachment = new TerminalAttachment(process, {
    retentionMs: 60_000,
    detachGraceMs: 1,
    detachedSize: async () => undefined,
  });
  const phone = makeClient();
  attachment.claim(phone);
  attachment.resize(44, 22);

  attachment.release(phone);
  await new Promise((resolve) => setTimeout(resolve, 15));
  assert.deepEqual(process.resizes.at(-1), { cols: 44, rows: 22 });
  attachment.dispose();
});

test("a phone that re-claims before the desktop size arrives keeps its own size", async () => {
  const process = new FakeProcess();
  let resolveSize: (size: { cols: number; rows: number }) => void = () => undefined;
  const attachment = new TerminalAttachment(process, {
    retentionMs: 60_000,
    detachGraceMs: 1,
    detachedSize: () => new Promise((resolve) => (resolveSize = resolve)),
  });
  const first = makeClient();
  attachment.claim(first);
  attachment.release(first);
  // The grace elapses and herdr is asked; the phone comes back before it answers.
  await new Promise((resolve) => setTimeout(resolve, 10));
  const second = makeClient();
  attachment.claim(second);
  attachment.resize(44, 22);

  resolveSize({ cols: 174, rows: 49 });
  await new Promise((resolve) => setTimeout(resolve, 5));
  assert.deepEqual(process.resizes.at(-1), { cols: 44, rows: 22 });
  attachment.dispose();
});

test("a drop that re-claims inside the grace window never resizes the desktop (#63)", async () => {
  const process = new FakeProcess();
  let asked = 0;
  const attachment = new TerminalAttachment(process, {
    retentionMs: 60_000,
    detachGraceMs: 30,
    detachedSize: async () => {
      asked += 1;
      return { cols: 174, rows: 49 };
    },
  });
  const phone = makeClient();
  attachment.claim(phone);
  attachment.resize(41, 28);

  attachment.release(phone);
  await new Promise((resolve) => setTimeout(resolve, 10));
  const again = makeClient();
  attachment.claim(again);
  await new Promise((resolve) => setTimeout(resolve, 50));

  // No resize at all after the phone's own — the flap was invisible to the Mac.
  assert.deepEqual(process.resizes, [{ cols: 41, rows: 28 }]);
  assert.equal(asked, 0);
  attachment.dispose();
});

test("a release that outlives the grace window hands back exactly once (#63)", async () => {
  const process = new FakeProcess();
  let asked = 0;
  const attachment = new TerminalAttachment(process, {
    retentionMs: 60_000,
    detachGraceMs: 10,
    detachedSize: async () => {
      asked += 1;
      return { cols: 174, rows: 49 };
    },
  });
  const phone = makeClient();
  attachment.claim(phone);
  attachment.resize(41, 28);

  attachment.release(phone);
  await new Promise((resolve) => setTimeout(resolve, 5));
  assert.deepEqual(process.resizes, [{ cols: 41, rows: 28 }], "resized before the grace elapsed");
  await new Promise((resolve) => setTimeout(resolve, 40));
  assert.deepEqual(process.resizes, [
    { cols: 41, rows: 28 },
    { cols: 174, rows: 49 },
  ]);
  assert.equal(asked, 1);

  // A later re-claim is a real client with a real grid.
  const later = makeClient();
  attachment.claim(later);
  attachment.resize(41, 28);
  assert.deepEqual(process.resizes.at(-1), { cols: 41, rows: 28 });
  attachment.dispose();
});

test("dispose inside the grace window cancels the hand-back", async () => {
  const process = new FakeProcess();
  let asked = 0;
  const attachment = new TerminalAttachment(process, {
    retentionMs: 60_000,
    detachGraceMs: 10,
    detachedSize: async () => {
      asked += 1;
      return { cols: 174, rows: 49 };
    },
  });
  const phone = makeClient();
  attachment.claim(phone);
  attachment.release(phone);
  attachment.dispose();
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.equal(asked, 0);
  assert.equal(process.resizes.length, 0);
});

test("unclaimed attachment disposes after retention", async () => {
  const process = new FakeProcess();
  const attachment = new TerminalAttachment(process, { retentionMs: 20 });
  await new Promise((resolve) => setTimeout(resolve, 60));
  assert.ok(attachment.isDisposed);
  assert.ok(process.killed);
});

test("terminal exit notifies the client and removes the attachment from the store", () => {
  const store = new AttachmentStore({ retentionMs: 60_000 });
  const process = new FakeProcess();
  const attachment = store.create("fixture", process);
  const client = makeClient();
  attachment.claim(client);

  process.emitExit(0, 15);

  assert.deepEqual(client.exits, [{ code: 0, signal: 15 }]);
  assert.ok(attachment.isDisposed);
  assert.equal(store.get("fixture"), undefined);
  assert.ok(!process.killed);
});

test("supersede tells the client it lost the terminal, exactly once", () => {
  const store = new AttachmentStore({ retentionMs: 60_000 });
  const process = new FakeProcess();
  const attachment = store.create("fixture", process);
  const client = makeClient();
  attachment.claim(client);

  attachment.supersede();

  assert.equal(client.superseded, 1);
  assert.deepEqual(client.exits, []);
  assert.ok(attachment.isDisposed);
  assert.ok(process.killed);
  assert.equal(store.get("fixture"), undefined);

  attachment.supersede();
  assert.equal(client.superseded, 1);
});

test("supersede after an exit leaves the exit as the client's only outcome", () => {
  const process = new FakeProcess();
  const attachment = new TerminalAttachment(process, { retentionMs: 60_000 });
  const client = makeClient();
  attachment.claim(client);

  process.emitExit(0);
  attachment.supersede();

  assert.deepEqual(client.exits, [{ code: 0 }]);
  assert.equal(client.superseded, 0);
});

test("store create supersedes the client of the attachment it replaces", () => {
  const store = new AttachmentStore({ retentionMs: 60_000 });
  const first = new FakeProcess();
  const original = store.create("fixture", first);
  const loser = makeClient();
  original.claim(loser);

  const second = new FakeProcess();
  const replacement = store.create("fixture", second);
  const winner = makeClient();
  replacement.claim(winner);

  assert.equal(loser.superseded, 1);
  assert.ok(original.isDisposed);
  assert.ok(first.killed);

  // The loser's socket closes late, against either attachment: neither
  // release may take the terminal from the client that now holds it.
  original.release(loser);
  replacement.release(loser);
  second.emitData("still theirs");
  assert.equal(winner.outputs, 1);
  assert.equal(winner.superseded, 0);
  assert.ok(!replacement.isDisposed);

  store.disposeAll();
});

test("store create replaces an existing attachment", () => {
  const store = new AttachmentStore({ retentionMs: 60_000 });
  const first = new FakeProcess();
  const second = new FakeProcess();
  const original = store.create("fixture", first);
  const replacement = store.create("fixture", second);

  assert.ok(original.isDisposed);
  assert.ok(first.killed);
  assert.ok(!replacement.isDisposed);
  assert.equal(store.get("fixture"), replacement);
  assert.notEqual(original.stream, replacement.stream);

  store.disposeAll();
  assert.ok(second.killed);
});

test("counters report the attach history the chaos view reads (#111)", async () => {
  const process = new FakeProcess();
  const attachment = new TerminalAttachment(process, {
    retentionMs: 60_000,
    detachGraceMs: 1,
    detachedSize: async () => ({ cols: 174, rows: 49 }),
  });
  const first = makeClient();
  attachment.claim(first);
  attachment.noteReady(false, 0);
  process.emitData("hello");

  const second = makeClient();
  attachment.claim(second);
  attachment.noteReady(true, 5);
  assert.deepEqual(attachment.counters(), {
    stream: attachment.stream,
    startOffset: 0,
    endOffset: 5,
    claims: 2,
    resumeHits: 1,
    resumeMisses: 1,
    supersedes: 1,
    lastReadyOffset: 5,
  });

  attachment.release(second);
  await new Promise((resolve) => setTimeout(resolve, 15));
  const released = attachment.counters();
  assert.ok(released.releasedAt !== undefined && released.releasedAt <= Date.now());
  assert.ok(released.resizedAt !== undefined && released.resizedAt >= released.releasedAt);
  attachment.dispose();
});
