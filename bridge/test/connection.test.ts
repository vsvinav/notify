import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer, type Socket } from "node:net";
import { once } from "node:events";
import { writeFile, rm } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { resolve } from "node:path";
import { Bridge } from "../dist/connection.js";
import { attachSubagents } from "../dist/subagents.js";

test("transport disconnect resets idle observation and reconnect cannot reuse an old age", { timeout: 5000 }, async t => {
  let now = 0, peer: Socket | undefined;
  t.mock.method(performance, "now", () => now);
  const config = resolve(`.connection-fixture-${randomUUID()}.json`);
  const server = createServer(socket => {
    peer = socket;
    socket.once("data", () => socket.write(JSON.stringify({ type: "welcome", sessionID: "fixture" }) + "\n"));
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const address = server.address();
  assert.ok(address && typeof address === "object");
  await writeFile(config, JSON.stringify({ port: address.port, token: "synthetic" }), { mode: 0o600 });
  const bridge = new Bridge("copilot", process.cwd(), config, "fixture", false);
  let listener: (event: any) => void = () => {};
  let reads = 0;
  const session = {
    rpc: { tasks: {
      list: async () => { reads++; return { tasks: [{
        type: "agent", id: "child", toolCallId: "tool-child", status: "idle",
        startedAt: "2020-01-01", agentType: "task", description: "fixture"
      }] }; },
      cancel: async () => { throw new Error("No real cancellation in this fixture"); }
    } },
    on: (callback: typeof listener) => { listener = callback; return () => {}; }
  };
  const tracker = attachSubagents(session as any, bridge);
  const settle = async (condition: () => boolean) => {
    for (let i = 0; i < 100 && !condition(); i++) await new Promise(resolve => setTimeout(resolve, 5));
    assert.ok(condition());
  };
  try {
    await bridge.start();
    await settle(() => reads > 0);
    listener({ type: "subagent.started", data: { toolCallId: "tool-child" } });
    await tracker.refresh();
    assert.equal(tracker.cleanupAvailable, true);
    now = 600001;
    peer!.destroy();
    await settle(() => !tracker.cleanupAvailable);
    assert.equal((await tracker.stopIdleSubagents()).cancelled, 0);
    now = 1200002;
    const previousReads = reads;
    await bridge.start();
    await settle(() => reads > previousReads);
    assert.equal((await tracker.stopIdleSubagents()).cancelled, 0, "Reconnect starts a fresh idle interval");
  } finally {
    tracker.stop(); bridge.stop(); peer?.destroy();
    await new Promise<void>(resolve => server.close(() => resolve()));
    await rm(config, { force: true });
  }
});

test("pending requests reject stale replies and resolve only once", async () => {
  const { PendingRequests } = await import("../src/pending.ts");
  const pending = new PendingRequests();
  const request = { id: "one", kind: "permission" as const, title: "Allow?", detail: "", questions: [], autoEligible: false };
  const result = pending.add(request);
  assert.equal(pending.reply({ requestID: "other", decision: "allow" }), false);
  assert.equal(pending.reply({ requestID: "one", decision: "answer" }), false);
  assert.equal(pending.requests.length, 1);
  assert.equal(pending.reply({ requestID: "one", decision: "deny" }), true);
  assert.equal((await result).decision, "deny");
  assert.equal(pending.reply({ requestID: "one", decision: "allow" }), false);
  assert.equal(pending.requests.length, 0);
});

test("cancelling a request cannot leave an actionable stale prompt", async () => {
  const { PendingRequests } = await import("../src/pending.ts");
  const pending = new PendingRequests();
  const controller = new AbortController();
  const result = pending.add({ id: "cancel", kind: "permission", title: "Allow?", detail: "", questions: [], autoEligible: false }, controller.signal);
  controller.abort();
  assert.equal((await result).decision, "deny");
  assert.equal(pending.requests.length, 0);
});

test("ended transports discard callbacks without replying into a closed SDK", async () => {
  const { PendingRequests } = await import("../src/pending.ts");
  const pending = new PendingRequests();
  let callbackReturned = false;
  void pending.add({ id: "ended", kind: "permission", title: "Allow?", detail: "", questions: [], autoEligible: false })
    .then(() => { callbackReturned = true; });
  pending.discardAll();
  assert.equal(pending.requests.length, 0);
  assert.equal(pending.reply({ requestID: "ended", decision: "allow" }), false);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(callbackReturned, false);
});

test("scope validation cannot race duplicate clicks or a terminal cancellation", async () => {
  const { PendingRequests } = await import("../src/pending.ts");
  const pending = new PendingRequests();
  let finish!: () => void;
  const result = pending.add({
    id: "scope", kind: "permission", title: "Allow?", detail: "", questions: [], autoEligible: false,
    permissionOptions: [{ id: "session", label: "This session", detail: "One command pattern" }]
  }, undefined, () => new Promise<void>(resolve => { finish = resolve; }));
  const reply = { requestID: "scope", decision: "allow", permissionOptionID: "session" };
  assert.equal(pending.reply(reply), false, "Synchronous replies cannot bypass scope validation");
  const sending = pending.submit(reply);
  assert.equal(await pending.submit(reply), false, "A second click cannot start another validation");
  pending.cancel("scope");
  finish();
  assert.equal(await sending, false, "A cancelled request cannot be approved after a slow lookup");
  assert.equal((await result).cancelled, true);
});
