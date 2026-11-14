import { test } from "node:test";
import assert from "node:assert/strict";

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
