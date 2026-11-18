import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { attachSubagents } from "../dist/subagents.js";

async function harness(overrides = {}, team) {
  const { attachSteering } = await import("../dist/steering.js");
  const statuses = [], calls = [], errors = [];
  let listener;
  const bridge = {
    setCapabilities: value => { bridge.capabilities = value; },
    error: value => errors.push(String(value)),
    controlStatus: (id, status, text) => statuses.push({ id, status, text })
  };
  const session = {
    on: callback => { listener = callback; return () => {}; },
    send: async value => { calls.push(["send", value]); return "runtime-message"; },
    abort: async () => { calls.push(["stop"]); },
    rpc: { interruptMainTurn: async value => { calls.push(["interrupt", value]); return { interrupted: true }; } },
    ...overrides
  };
  const attachment = attachSteering(session, bridge, team);
  await attachment.ready;
  return { bridge, session, calls, statuses, errors, attachment, emit: event => listener(event) };
}

const cleanupCommand = () => ({ commandID: randomUUID(), action: "stop_idle_subagents", text: "" });
test("main Send steers without interruption and awaits correlated consumption", async () => {
  const h = await harness();
  const command = { commandID: randomUUID(), action: "send", text: "Adjust the current approach" };
  await assert.doesNotReject(h.bridge.onControl(command));
  assert.equal(h.bridge.capabilities.steeringImmediate, true);
  assert.deepEqual(h.calls, [["send", { prompt: command.text, mode: "immediate", clientTurnId: command.commandID }]]);
  assert.equal(h.statuses.at(-1).status, "submitted");
  await h.bridge.onControl(command);
  assert.equal(h.calls.length, 1, "Duplicate Send must never be dispatched twice");
  h.emit({ type: "user.message", data: { clientTurnId: randomUUID() } });
  assert.equal(h.statuses.at(-1).status, "submitted");
  h.emit({ type: "user.message", data: { clientTurnId: command.commandID } });
  assert.equal(h.statuses.at(-1).status, "received");
  await assert.rejects(h.bridge.onControl({ ...command, text: "Changed" }), /changed/);
  await assert.rejects(h.bridge.onControl({ ...command, commandID: randomUUID(), agentID: "child" }), /invalid/i);
  h.attachment.stop();
  assert.equal(h.bridge.capabilities.steeringImmediate, false);
});

test("main Send cannot regress early consumption or retry an uncertain dispatch", async () => {
  const h = await harness();
  h.session.send = async value => {
    h.calls.push(["send", value]);
    h.emit({ type: "user.message", data: { clientTurnId: value.clientTurnId } });
  };
  await assert.doesNotReject(h.bridge.onControl({ commandID: randomUUID(), action: "send", text: "Early event" }));
  assert.equal(h.statuses.at(-1).status, "received");
  const uncertain = { commandID: randomUUID(), action: "send", text: "Lost acknowledgment" };
  h.session.send = async value => { h.calls.push(["send", value]); throw new Error("Synthetic lost acknowledgment"); };
  await h.bridge.onControl(uncertain);
  assert.equal(h.statuses.at(-1).status, "unknown");
  await h.bridge.onControl(uncertain);
  assert.equal(h.calls.length, 2, "Uncertain Send must not be replayed");
});

async function cleanupHarness(t) {
  let now = 0;
  t.mock.method(performance, "now", () => now);
  const listeners = new Set(), cancellations = [];
  const tasks = {
    list: async () => ({ tasks: ["one", "two"].map(id => ({
      id, toolCallId: `tool-${id}`, type: "agent", status: "idle", startedAt: "2020-01-01",
      description: "helper", agentType: "task"
    })) }),
    cancel: async ({ id }) => { cancellations.push(id); return { cancelled: true }; }
  };
  const session = { rpc: { tasks }, on: callback => { listeners.add(callback); return () => listeners.delete(callback); } };
  const tracker = attachSubagents(session, { team() {} });
  const h = await harness(session, tracker);
  const emit = event => { for (const listener of listeners) listener(event); };
  for (const id of ["one", "two"]) emit({ type: "subagent.started", data: { toolCallId: `tool-${id}` } });
  t.after(() => { h.attachment.stop(); tracker.stop(); });
  return { ...h, tracker, tasks, cancellations, emit, time: value => { now = value; } };
}

test("cleanup advertises only observed support, uses dedup/busy receipts, and is never main chat", async t => {
  const h = await cleanupHarness(t);
  assert.equal(h.bridge.capabilities.idleSubagentCleanup, false);
  await h.tracker.refresh();
  assert.equal(h.bridge.capabilities.idleSubagentCleanup, true);
  h.time(600001);
  let finish;
  h.tasks.cancel = ({ id }) => { h.cancellations.push(id); return new Promise(resolve => { finish = resolve; }); };
  const command = cleanupCommand(), pending = h.bridge.onControl(command);
  await new Promise(resolve => setImmediate(resolve));
  await h.bridge.onControl(command);
  assert.equal(h.statuses.at(-1).status, "sending");
  await assert.rejects(h.bridge.onControl(cleanupCommand()), /still being delivered/);
  finish({ cancelled: false });
  await pending;
  assert.equal(h.statuses.at(-1).status, "failed");
  assert.match(h.statuses.at(-1).text, /Cancelled 0; skipped 1; failed 1; uncertain 0/);
  await h.bridge.onControl(command);
  assert.equal(h.cancellations.length, 1);
  await assert.rejects(h.bridge.onControl({ ...command, action: "stop" }), /changed/);
  h.tasks.cancel = async ({ id }) => { h.cancellations.push(id); return { cancelled: true }; };
  const next = cleanupCommand();
  await h.bridge.onControl(next);
  assert.equal(h.statuses.at(-1).status, "cleaned");
  h.emit({ type: "user.message", data: { clientTurnId: next.commandID } });
  assert.equal(h.statuses.at(-1).status, "cleaned");
  assert.deepEqual(h.calls, [], "No main send/abort");
});

test("cleanup strictly rejects targeting/text and unsupported providers never fall back to main", async () => {
  const h = await harness();
  assert.equal(h.bridge.capabilities.idleSubagentCleanup, false);
  for (const fields of [{ text: " " }, { text: "stop" }, { agentID: "one" }, { agentName: "helper" },
    { agentType: "task" }, { model: "model" }]) {
    await assert.rejects(h.bridge.onControl({ ...cleanupCommand(), ...fields }), /invalid/i);
  }
  await h.bridge.onControl(cleanupCommand());
  assert.equal(h.statuses.at(-1).status, "failed");
  assert.deepEqual(h.calls, []);
});

test("partial cleanup keeps explicit counts and does not retry an uncertain cancellation", async t => {
  const h = await cleanupHarness(t);
  await h.tracker.refresh();
  h.time(600001);
  h.tasks.cancel = async ({ id }) => {
    h.cancellations.push(id);
    if (h.cancellations.length === 2) throw new Error("lost ACK");
    return { cancelled: true };
  };
  const command = cleanupCommand();
  await h.bridge.onControl(command);
  assert.equal(h.statuses.at(-1).status, "unknown");
  assert.match(h.statuses.at(-1).text, /Cancelled 1; skipped 0; failed 0; uncertain 1/);
  await h.bridge.onControl(command);
  assert.equal(h.cancellations.length, 2);
});

test("known failure after one cancellation reports partial failure, not cleaned", async t => {
  const h = await cleanupHarness(t);
  await h.tracker.refresh();
  h.time(600001);
  h.tasks.cancel = async ({ id }) => {
    h.cancellations.push(id);
    return { cancelled: h.cancellations.length === 1 };
  };
  await h.bridge.onControl(cleanupCommand());
  assert.equal(h.statuses.at(-1).status, "failed");
  assert.match(h.statuses.at(-1).text, /Cancelled 1; skipped 0; failed 1; uncertain 0/);
});

test("zero eligible helpers complete a cleanup without stopping the main or faking stopped state", async t => {
  const h = await cleanupHarness(t);
  await h.tracker.refresh();
  await h.bridge.onControl(cleanupCommand());
  assert.equal(h.statuses.at(-1).status, "cleaned");
  assert.match(h.statuses.at(-1).text, /Cancelled 0; skipped 2; failed 0; uncertain 0/);
  assert.deepEqual(h.cancellations, []);
  assert.deepEqual(h.calls, []);
});

test("cleanup detach during live recheck prevents dispatch and revokes capability", async t => {
  const h = await cleanupHarness(t);
  await h.tracker.refresh();
  h.time(600001);
  const original = h.tasks.list;
  let finish;
  h.tasks.list = () => new Promise(resolve => { finish = resolve; });
  const pending = h.bridge.onControl(cleanupCommand());
  h.attachment.stop();
  finish(await original());
  await pending;
  assert.equal(h.statuses.at(-1).status, "failed");
  assert.equal(h.bridge.capabilities.idleSubagentCleanup, false);
  assert.deepEqual(h.cancellations, []);
});

test("detach during an empty cleanup evaluation is a failure rather than a completed batch", async t => {
  const h = await cleanupHarness(t);
  let finish;
  h.tasks.list = () => new Promise(resolve => { finish = resolve; });
  const pending = h.bridge.onControl(cleanupCommand());
  h.attachment.stop();
  finish({ tasks: [] });
  await pending;
  assert.equal(h.statuses.at(-1).status, "failed");
});

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

test("child controls target only a live agent and retain exact receipt identity", async () => {
  const calls = [];
  const tasks = {
    list: async () => ({ tasks: [{ id: "worker", type: "agent", status: "idle" }] }),
    sendMessage: async value => { calls.push(["message", value]); return { sent: true }; },
    cancel: async value => { calls.push(["cancel", value]); return { cancelled: true }; }
  };
  const h = await harness({ rpc: { tasks } });
  assert.equal(h.bridge.capabilities.subagentChat, true);
  const command = { commandID: randomUUID(), action: "queue", text: "Check boundaries", agentID: "worker" };
  await h.bridge.onControl(command);
  assert.deepEqual(calls, [["message", { id: "worker", message: "Check boundaries" }]]);
  assert.equal(h.statuses.at(-1).status, "received");
  await h.bridge.onControl(command);
  assert.equal(calls.length, 1);
  await assert.rejects(h.bridge.onControl({ ...command, agentID: "other" }), /changed/i);
  await h.bridge.onControl({ commandID: randomUUID(), action: "stop", text: "", agentID: "worker" });
  assert.deepEqual(calls.at(-1), ["cancel", { id: "worker" }]);
  assert.equal(h.statuses.at(-1).status, "stopped");
  await h.bridge.onControl({ ...command, commandID: randomUUID(), agentID: "missing" });
  assert.equal(h.statuses.at(-1).status, "failed");
  assert.equal(h.calls.length, 0, "Never fall back to main send or abort");
  tasks.sendMessage = async () => ({ sent: false, error: "One-shot agent cannot receive messages" });
  await h.bridge.onControl({ ...command, commandID: randomUUID() });
  assert.equal(h.statuses.at(-1).status, "failed");
  await assert.rejects(h.bridge.onControl({ ...command, commandID: randomUUID(), agentID: "" }), /invalid/i);
});

function management(overrides = {}) {
  const calls = [];
  const rpc = {
    model: { list: async value => {
      calls.push(["models", value]); return { list: [{ id: "available", policy: { state: "enabled" } }, { id: "byok/local" },
        { id: "disabled", policy: { state: "disabled" } }, { id: "needs-consent", policy: { state: "unconfigured" } }],
        modelPriceCategories: [{ id: "metadata-only" }] };
    } },
    agent: { list: async value => {
      calls.push(["catalog", value]); return { agents: [{ id: "task", name: "task-runtime" }, { id: "general-purpose", name: "general-purpose" }] };
    } },
    tasks: {
      list: async () => ({ tasks: [{ id: "ended", type: "agent", status: "completed" }] }),
      startAgent: async value => { calls.push(["create", value]); return { agentId: "new-child" }; },
      remove: async value => { calls.push(["remove", value]); return { removed: true }; },
      ...overrides
    }
  };
  return { rpc, calls };
}
const creation = () => ({
  commandID: randomUUID(), action: "create_subagent", text: "Check the boundary",
  agentName: "Boundary helper", agentType: "task"
});

test("creation discovers live stable IDs, uses runtime model defaults and replays exact receipts", async () => {
  const m = management(), refreshes = [];
  const h = await harness({ rpc: m.rpc }, { refresh: async () => refreshes.push(h.statuses.at(-1).status) });
  assert.equal(h.bridge.capabilities.subagentCreate, true);
  assert.deepEqual(h.bridge.capabilities.subagentTypes, ["task", "general-purpose"]);
  assert.deepEqual(h.bridge.capabilities.subagentModels, ["available", "byok/local"]);
  assert.deepEqual(m.calls[0], ["catalog", { includeBuiltInAgents: true }]);
  assert.equal(m.calls.filter(c => c[0] === "create").length, 0, "Never create without a command");
  const command = creation();
  await h.bridge.onControl(command);
  assert.deepEqual(m.calls.at(-1), ["create", { agentType: "task-runtime", name: "Boundary helper", prompt: command.text }]);
  assert.equal(m.calls.filter(c => c[0] === "catalog").length, 2, "Revalidate immediately before creation");
  assert.equal(h.statuses.at(-1).status, "created");
  assert.match(h.statuses.at(-1).text, /Boundary helper/);
  assert.deepEqual(refreshes, ["created"]);
  h.emit({ type: "user.message", data: { clientTurnId: command.commandID } });
  assert.equal(h.statuses.at(-1).status, "created", "Management receipts are not chat receipts");
  await h.bridge.onControl(command);
  assert.equal(m.calls.filter(c => c[0] === "create").length, 1);
  for (const fields of [{ agentName: "Changed" }, { agentType: "general-purpose" }, { text: "Changed" }]) {
    await assert.rejects(h.bridge.onControl({ ...command, ...fields }), /changed/);
  }
  assert.equal(h.calls.length, 0);
  h.attachment.stop();
  assert.equal(h.bridge.capabilities.subagentCreate, false);
  assert.equal(h.bridge.capabilities.subagentRemove, false);
  assert.deepEqual(h.bridge.capabilities.subagentTypes, []);
  assert.deepEqual(h.bridge.capabilities.subagentModels, []);
});

test("management validates strict wire shapes and the live catalog without a main-chat fallback", async () => {
  const m = management(), h = await harness({ rpc: m.rpc });
  for (const fields of [{ agentName: "" }, { agentName: "😀".repeat(81) }, { agentType: " " },
    { agentType: "x".repeat(129) }, { text: "" }, { text: "😀".repeat(8001) }, { agentID: "ended" },
    { model: "" }, { model: " " }, { model: "😀".repeat(101) }]) {
    await assert.rejects(h.bridge.onControl({ ...creation(), ...fields }), /invalid/i);
  }
  for (const fields of [{ text: "not empty" }, { agentID: "" }, { agentName: "unexpected" }, { agentType: "task" }]) {
    await assert.rejects(h.bridge.onControl({ commandID: randomUUID(), action: "remove_subagent", text: "", agentID: "ended", ...fields }), /invalid/i);
  }
  m.rpc.agent.list = async () => ({ agents: [{ id: "general-purpose", name: "general-purpose" }] });
  await h.bridge.onControl(creation());
  assert.equal(h.statuses.at(-1).status, "failed");
  assert.match(h.statuses.at(-1).text, /available/);
  assert.equal(m.calls.filter(c => c[0] === "create").length, 0);
  assert.equal(h.calls.length, 0);
});

test("catalog failures and invalid responses disable creation explicitly; no invented types", async () => {
  for (const agents of [null, [{ name: "not-an-id" }], [{ id: " " }], [{ id: "task" }],
    [{ id: "task", name: "same" }, { id: "other", name: "same" }], [{ id: "task" }, { id: "task" }],
    Array.from({ length: 101 }, (_, i) => ({ id: String(i) }))]) {
    const m = management();
    m.rpc.agent.list = async () => ({ agents });
    const h = await harness({ rpc: m.rpc });
    assert.equal(h.bridge.capabilities.subagentCreate, false);
    assert.deepEqual(h.bridge.capabilities.subagentTypes, []);
    assert.match(h.errors[0], /catalog/i);
  }
  const m = management();
  m.rpc.agent.list = async () => { throw new Error("Lookup offline"); };
  const h = await harness({ rpc: m.rpc });
  assert.equal(h.bridge.capabilities.subagentCreate, false);
  await h.bridge.onControl(creation());
  assert.equal(h.statuses.at(-1).status, "failed");
  assert.match(h.statuses.at(-1).text, /Lookup offline/);
  assert.equal(m.calls.filter(c => c[0] === "create").length, 0);
  const unsupported = await harness();
  assert.equal(unsupported.bridge.capabilities.subagentCreate, false);
  assert.equal(unsupported.bridge.capabilities.subagentRemove, false);
});

test("only valid runtime management ACKs become created or removed; ambiguity is never retried", async () => {
  for (const result of [{}, { agentId: "" }, { agentId: " " }, { agentId: "x".repeat(129) }]) {
    const m = management({ startAgent: async () => result }), h = await harness({ rpc: m.rpc });
    await h.bridge.onControl(creation());
    assert.equal(h.statuses.at(-1).status, "unknown");
  }
  let count = 0;
  const m = management({ startAgent: async () => { count++; throw new Error("Lost ACK"); } });
  const h = await harness({ rpc: m.rpc }), command = creation();
  await h.bridge.onControl(command); await h.bridge.onControl(command);
  assert.equal(count, 1);
  assert.equal(h.statuses.at(-1).status, "unknown");
});

test("remove only dispatches to the exact ended agent and updates retained team after ACK", async () => {
  const m = management(), updates = [];
  const h = await harness({ rpc: m.rpc }, {
    removed: id => updates.push(["removed", id]),
    refresh: async () => updates.push(["refresh", h.statuses.at(-1).status]),
    isRetainedCancelled: id => id === "vanished"
  });

  assert.equal(h.bridge.capabilities.subagentRemove, true);
  const command = { commandID: randomUUID(), action: "remove_subagent", text: "", agentID: "ended" };
  await h.bridge.onControl(command); await h.bridge.onControl(command);
  assert.deepEqual(m.calls.filter(c => c[0] === "remove"), [["remove", { id: "ended" }]]);
  assert.deepEqual(updates, [["removed", "ended"], ["refresh", "removed"]]);
  await assert.rejects(h.bridge.onControl({ ...command, agentID: "different" }), /changed/);
  for (const task of [{ id: "ended", type: "agent", status: "running" }, { id: "ended", type: "agent", status: "idle" },
    { id: "ended", type: "shell", status: "completed" }]) {
    m.rpc.tasks.list = async () => ({ tasks: [task] });
    await h.bridge.onControl({ ...command, commandID: randomUUID() });
    assert.equal(h.statuses.at(-1).status, "failed");
  }
  await h.bridge.onControl({ ...command, commandID: randomUUID(), agentID: "vanished" });
  assert.equal(h.statuses.at(-1).status, "failed");
  assert.match(h.statuses.at(-1).text, /retained.*absent/i);
  assert.equal(m.calls.filter(c => c[0] === "remove").length, 1);
  m.rpc.tasks.list = async () => ({ tasks: [{ id: "ended", type: "agent", status: "cancelled" }] });
  m.rpc.tasks.remove = async () => ({ removed: false });
  await h.bridge.onControl({ ...command, commandID: randomUUID() });
  assert.equal(h.statuses.at(-1).status, "failed");
  assert.equal(updates.length, 2, "Do not delete cached rows without removed:true");
  assert.equal(h.calls.length, 0, "Remove must never stop or use the main chat");
});

test("pending management blocks new commands, replays sending, and detach prevents dispatch", async () => {
  let finish;
  const m = management(), h = await harness({ rpc: m.rpc });
  m.rpc.agent.list = () => new Promise(resolve => { finish = resolve; });
  const command = creation(), pending = h.bridge.onControl(command);
  await new Promise(resolve => setImmediate(resolve));
  await h.bridge.onControl(command);
  assert.equal(h.statuses.at(-1).status, "sending");
  await assert.rejects(h.bridge.onControl(creation()), /still being delivered/);
  h.attachment.stop();
  finish({ agents: [{ id: "task", name: "task-runtime" }] });
  await pending;
  assert.equal(h.statuses.at(-1).status, "failed");
  assert.equal(m.calls.filter(c => c[0] === "create").length, 0);
  assert.equal(h.bridge.capabilities.subagentCreate, false);
});

test("live catalog update failures revoke creation until a successful lookup", async () => {
  const m = management(), h = await harness({ rpc: m.rpc });
  m.rpc.agent.list = async () => { throw new Error("Catalog changed"); };
  h.emit({ type: "session.custom_agents_updated" });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(h.bridge.capabilities.subagentCreate, false);
  assert.deepEqual(h.bridge.capabilities.subagentTypes, []);
  assert.match(h.errors.at(-1), /Catalog changed/);
  m.rpc.agent.list = async () => ({ agents: [{ id: "task", name: "task-runtime" }] });
  h.emit({ type: "session.custom_agents_updated" });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(h.bridge.capabilities.subagentCreate, true);
  assert.deepEqual(h.bridge.capabilities.subagentTypes, ["task"]);
});

test("explicit models use only freshly validated selectable session IDs and participate in receipt identity", async () => {
  const m = management(), h = await harness({ rpc: m.rpc });
  const command = { ...creation(), model: "byok/local" };
  await h.bridge.onControl(command);
  assert.equal(h.statuses.at(-1).status, "created");
  assert.deepEqual(m.calls.at(-1), ["create", {
    agentType: "task-runtime", name: command.agentName, prompt: command.text, model: "byok/local"
  }]);
  assert.deepEqual(m.calls.filter(c => c[0] === "models"), [["models", { skipCache: true }], ["models", { skipCache: true }]]);
  await h.bridge.onControl(command);
  assert.equal(m.calls.filter(c => c[0] === "create").length, 1);
  for (const model of [undefined, "available"]) await assert.rejects(h.bridge.onControl({ ...command, model }), /changed/);
  m.rpc.model.list = async () => ({ list: [{ id: "available" }] });
  await h.bridge.onControl({ ...command, commandID: randomUUID() });
  assert.equal(h.statuses.at(-1).status, "failed");
  assert.match(h.statuses.at(-1).text, /model.*available/i);
  assert.equal(m.calls.filter(c => c[0] === "create").length, 1);
});

test("invalid or unavailable model catalogs disable selection but preserve configured-default creation", async () => {
  for (const list of [null, [{ id: " " }], [{ id: "x".repeat(201) }], [{ id: "same" }, { id: "same" }],
    Array.from({ length: 201 }, (_, i) => ({ id: String(i) }))]) {
    const m = management();
    m.rpc.model.list = async () => ({ list });
    const h = await harness({ rpc: m.rpc });
    assert.deepEqual(h.bridge.capabilities.subagentModels, []);
    assert.equal(h.bridge.capabilities.subagentCreate, true);
    assert.match(h.errors.at(-1), /model catalog/i);
    await h.bridge.onControl({ ...creation(), model: "available" });
    assert.equal(h.statuses.at(-1).status, "failed");
    await h.bridge.onControl(creation());
    assert.equal(h.statuses.at(-1).status, "created");
    assert.equal("model" in m.calls.at(-1)[1], false);
  }
  for (const modelAPI of [undefined, { list: async () => { throw new Error("Model lookup denied"); } }]) {
    const m = management();
    m.rpc.model = modelAPI;
    const h = await harness({ rpc: m.rpc });
    assert.deepEqual(h.bridge.capabilities.subagentModels, []);
    await h.bridge.onControl({ ...creation(), model: "available" });
    assert.equal(h.statuses.at(-1).status, "failed");
    await h.bridge.onControl(creation());
    assert.equal(h.statuses.at(-1).status, "created");
  }
});
