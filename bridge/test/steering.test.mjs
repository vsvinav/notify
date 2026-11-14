import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

async function harness(overrides = {}) {
  const { attachSteering } = await import("../dist/steering.js");
  const statuses = [], calls = [];
  let listener;
  const bridge = {
    setCapabilities: value => { bridge.capabilities = value; },
    controlStatus: (id, status, text) => statuses.push({ id, status, text })
  };
  const session = {
    on: callback => { listener = callback; return () => {}; },
    send: async value => { calls.push(["send", value]); return "runtime-message"; },
    abort: async () => { calls.push(["stop"]); },
    rpc: { interruptMainTurn: async value => { calls.push(["interrupt", value]); return { interrupted: true }; } },
    ...overrides
  };
  const attachment = attachSteering(session, bridge);
  return { bridge, session, calls, statuses, attachment, emit: event => listener(event) };
}

test("queued steering is accepted once and received only after the matching runtime event", async () => {
  const h = await harness();
  const command = { commandID: randomUUID(), action: "queue", text: "Use the existing helper" };
  await h.bridge.onControl(command);
  assert.equal(h.statuses.at(-1).status, "queued");
  assert.deepEqual(h.calls[0][1], { prompt: command.text, mode: "enqueue", clientTurnId: command.commandID });
  h.emit({ type: "user.message", data: { clientTurnId: "different" } });
  assert.equal(h.statuses.at(-1).status, "queued");
  h.emit({ type: "user.message", data: { clientTurnId: command.commandID } });
  assert.equal(h.statuses.at(-1).status, "received");
  await h.bridge.onControl(command);
  assert.equal(h.calls.length, 1);
  assert.equal(h.statuses.at(-1).status, "received");
});

test("a received event before send acknowledgment cannot regress to queued", async () => {
  let accept;
  const h = await harness({ send: () => new Promise(resolve => { accept = resolve; }) });
  const command = { commandID: randomUUID(), action: "queue", text: "Add a regression test" };
  const sent = h.bridge.onControl(command);
  h.emit({ type: "user.message", data: { clientTurnId: command.commandID } });
  accept("message");
  await sent;
  assert.equal(h.statuses.at(-1).status, "received");
});

test("interrupt preserves the terminal queue; stop never closes the original session", async () => {
  const h = await harness();
  await h.bridge.onControl({ commandID: randomUUID(), action: "interrupt", text: "Keep the API unchanged" });
  assert.deepEqual(h.calls[0], ["interrupt", { flushQueued: true }]);
  assert.equal(h.calls[1][1].mode, "immediate");
  await h.bridge.onControl({ commandID: randomUUID(), action: "stop", text: "" });
  assert.deepEqual(h.calls.at(-1), ["stop"]);
  assert.equal(h.statuses.at(-1).status, "stopped");
  h.attachment.stop();
  assert.equal(h.calls.length, 3, "detaching must never stop the original owner");
});

test("ambiguous send failures are not retried and invalid input never reaches the runtime", async () => {
  let count = 0;
  const h = await harness({ send: async () => { count++; throw new Error("Connection lost"); } });
  const command = { commandID: randomUUID(), action: "queue", text: "Run tests" };
  await h.bridge.onControl(command);
  assert.equal(h.statuses.at(-1).status, "unknown");
  await h.bridge.onControl(command);
  assert.equal(count, 1);
  await assert.rejects(h.bridge.onControl({ commandID: randomUUID(), action: "queue", text: " " }), /invalid/i);
  await assert.rejects(h.bridge.onControl({ commandID: randomUUID(), action: "shell", text: "rm" }), /invalid/i);
  assert.equal(count, 1);
});
