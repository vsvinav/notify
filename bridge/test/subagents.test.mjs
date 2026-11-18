import { test } from "node:test";
import assert from "node:assert/strict";
import { attachSubagents } from "../dist/subagents.js";

function fixture(list, cancel) {
  const snapshots = [];
  let receive;
  const tracker = attachSubagents({
    rpc: { tasks: { list, cancel } },
    on(handler) { receive = handler; return () => { receive = undefined; }; }
  }, { team(snapshot) { snapshots.push(snapshot); } });
  return { tracker, snapshots, emit: event => receive?.(event) };
}

const agent = (id, status = "running") => ({
  type: "agent", id, toolCallId: `tool-${id}`, description: `Task ${id}`, displayName: `Helper ${id}`,
  status, startedAt: "2026-11-15T01:00:00Z", agentType: "explore", prompt: "Private full prompt",
  result: "Private full result", model: "configured-model", resolvedModel: "actual-model"
});

function cleanupFixture(t, initial = [agent("old", "idle")]) {
  let now = 0, tasks = initial, listError, cancelResult = { cancelled: true };
  t.mock.method(performance, "now", () => now);
  const calls = [];
  const f = fixture(async () => {
    if (listError) throw listError;
    return { tasks };
  }, async ({ id }) => {
    calls.push(id);
    if (cancelResult instanceof Error) throw cancelResult;
    if (cancelResult.cancelled) tasks = tasks.map(task => task.id === id ? { ...task, status: "cancelled" } : task);
    return cancelResult;
  });
  for (const task of initial) f.emit({ type: "subagent.started", data: { toolCallId: task.toolCallId } });
  t.after(() => f.tracker.stop());
  return { ...f, calls, time: value => { now = value; }, tasks: value => { tasks = value; },
    error: value => { listError = value; }, result: value => { cancelResult = value; } };
}

test("manual cleanup uses strictly more than ten observed monotonic idle minutes, never startedAt", async t => {
  const f = cleanupFixture(t);
  assert.equal(f.tracker.cleanupAvailable, false);
  await f.tracker.refresh();
  assert.equal(f.tracker.cleanupAvailable, true);
  f.time(600000);
  assert.equal((await f.tracker.stopIdleSubagents()).cancelled, 0);
  f.time(600001);
  const result = await f.tracker.stopIdleSubagents();
  assert.equal(result.status, "cleaned");
  assert.equal(result.cancelled, 1);
  assert.deepEqual(f.calls, ["old"]);
});

test("idle activity and changed snapshots restart the entire observed idle interval", async t => {
  const f = cleanupFixture(t);
  await f.tracker.refresh();
  f.time(600001);
  f.tasks([agent("old", "running")]);
  await f.tracker.refresh();
  f.tasks([agent("old", "idle")]);
  await f.tracker.refresh();
  assert.equal((await f.tracker.stopIdleSubagents()).cancelled, 0);
  f.time(1200002);
  f.emit({ type: "assistant.message_delta", agentId: "old", data: { deltaContent: "work between snapshots" } });
  assert.equal((await f.tracker.stopIdleSubagents()).cancelled, 0);
  f.time(1800003);
  f.emit({ type: "session.background_tasks_changed", data: {} });
  assert.equal((await f.tracker.stopIdleSubagents()).cancelled, 0);
  f.time(2400004);
  f.tasks([{ ...agent("old", "idle"), description: "Changed while still idle" }]);
  assert.equal((await f.tracker.stopIdleSubagents()).cancelled, 0);
  assert.deepEqual(f.calls, []);
});

test("unknown age, errors, removal and disconnect never retain old eligibility", async t => {
  const f = cleanupFixture(t);
  f.time(600001);
  assert.equal((await f.tracker.stopIdleSubagents()).cancelled, 0, "First observation is not ten minutes old");
  f.time(1200002);
  f.error(new Error("offline"));
  await f.tracker.refresh();
  assert.equal(f.tracker.cleanupAvailable, false);
  assert.equal((await f.tracker.stopIdleSubagents()).status, "failed");
  f.error(undefined);
  assert.equal((await f.tracker.stopIdleSubagents()).cancelled, 0);
  f.time(1800003);
  f.tracker.resetIdleObservation();
  assert.equal(f.tracker.cleanupAvailable, false);
  assert.equal((await f.tracker.stopIdleSubagents()).cancelled, 0);
  f.time(2400004);
  f.tracker.removed("old");
  assert.equal((await f.tracker.stopIdleSubagents()).cancelled, 0);
  assert.deepEqual(f.calls, []);
});

test("running or young descendants protect ancestors; eligible trees cancel deepest first", async t => {
  const f = cleanupFixture(t, [agent("parent", "idle"), agent("child", "running"), agent("sibling", "idle")]);
  f.emit({ type: "subagent.started", data: { toolCallId: "tool-child", parentId: "parent" } });
  await f.tracker.refresh();
  f.time(600001);
  let result = await f.tracker.stopIdleSubagents();
  assert.deepEqual(f.calls, ["sibling"]);
  assert.equal(result.skipped, 2);
  f.tasks([agent("parent", "idle"), agent("child", "idle")]);
  await f.tracker.refresh();
  assert.equal((await f.tracker.stopIdleSubagents()).cancelled, 0);
  f.time(1200002);
  result = await f.tracker.stopIdleSubagents();
  assert.equal(result.status, "cleaned");
  assert.deepEqual(f.calls, ["sibling", "child", "parent"]);
});

test("unknown, missing and cyclic ancestry safely block potential ancestors", async t => {
  const f = cleanupFixture(t, [agent("known", "idle")]);
  f.tasks([agent("known", "idle"), agent("unknown", "running")]);
  await f.tracker.refresh();
  f.time(600001);
  let result = await f.tracker.stopIdleSubagents();
  assert.equal(result.cancelled, 0);
  assert.match(result.text, /ancestry/i);
  f.emit({ type: "subagent.started", data: { toolCallId: "tool-unknown", parentId: "missing" } });
  await f.tracker.refresh();
  f.time(1200002);
  assert.equal((await f.tracker.stopIdleSubagents()).cancelled, 0);
  f.emit({ type: "subagent.started", data: { toolCallId: "tool-unknown", parentId: "known" } });
  f.emit({ type: "subagent.started", data: { toolCallId: "tool-known", parentId: "unknown" } });
  await f.tracker.refresh();
  f.time(1800003);
  assert.equal((await f.tracker.stopIdleSubagents()).cancelled, 0);
  assert.deepEqual(f.calls, []);
});

test("cleanup rechecks live status before each cancellation and fences activity during reads", async t => {
  let now = 0, reads = 0, calls = [];
  t.mock.method(performance, "now", () => now);
  const f = fixture(async () => {
    reads++;
    if (reads === 3) return { tasks: [agent("old", "running")] };
    return { tasks: [agent("old", "idle")] };
  }, async value => { calls.push(value); return { cancelled: true }; });
  t.after(() => f.tracker.stop());
  f.emit({ type: "subagent.started", data: { toolCallId: "tool-old" } });
  await f.tracker.refresh();
  now = 600001;
  assert.equal((await f.tracker.stopIdleSubagents()).cancelled, 0);
  assert.equal(reads, 3);
  assert.deepEqual(calls, []);

  let finish;
  const stale = fixture(() => new Promise(resolve => { finish = resolve; }), async () => ({ cancelled: true }));
  t.after(() => stale.tracker.stop());
  const pending = stale.tracker.refresh();
  stale.emit({ type: "session.background_tasks_changed", data: {} });
  finish({ tasks: [agent("old", "idle")] });
  await pending;
  assert.equal(stale.tracker.cleanupAvailable, false);
});

test("partial false ACKs fail and thrown or malformed ACKs are uncertain, never all-success", async t => {
  const f = cleanupFixture(t, [agent("one", "idle"), agent("two", "idle")]);
  await f.tracker.refresh();
  f.time(600001);
  f.result({ cancelled: false });
  let result = await f.tracker.stopIdleSubagents();
  assert.equal(result.status, "failed");
  assert.equal(result.failed, 1);
  assert.equal(result.skipped, 1);
  f.result(new Error("lost ACK"));
  result = await f.tracker.stopIdleSubagents();
  assert.equal(result.status, "unknown");
  assert.equal(result.unknown, 1);
  f.result({});
  assert.equal((await f.tracker.stopIdleSubagents()).status, "unknown");
});

test("unsupported and detached trackers cannot cancel", async () => {
  const f = fixture(async () => ({ tasks: [agent("old", "idle")] }));
  await f.tracker.refresh();
  assert.equal(f.tracker.cleanupAvailable, false);
  assert.equal((await f.tracker.stopIdleSubagents()).status, "failed");
  f.tracker.stop();
  assert.equal((await f.tracker.stopIdleSubagents()).status, "failed");
});

test("streamed activity invalidates idle age without adding task-list reads per token", async t => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  let reads = 0;
  const f = fixture(async () => { reads++; return { tasks: [agent("old", "idle")] }; }, async () => ({ cancelled: true }));
  t.after(() => f.tracker.stop());
  await f.tracker.refresh();
  for (let i = 0; i < 1000; i++) f.emit({ type: "assistant.message_delta", agentId: "old", data: {} });
  t.mock.timers.tick(100);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(reads, 1, "Activity must invalidate synchronously, not schedule per-token task-list RPCs");
});

test("session shutdown and resume reset observation instead of reusing pre-reload idle ages", async t => {
  const f = cleanupFixture(t);
  await f.tracker.refresh();
  f.time(600001);
  f.emit({ type: "session.shutdown", data: {} });
  assert.equal(f.tracker.cleanupAvailable, false);
  assert.equal((await f.tracker.stopIdleSubagents()).status, "failed");
  f.emit({ type: "session.resume", data: {} });
  assert.equal((await f.tracker.stopIdleSubagents()).cancelled, 0);
  assert.deepEqual(f.calls, []);
});

test("bounded observation rejects duplicate identities and oversized snapshots safely", async t => {
  const f = cleanupFixture(t);
  await f.tracker.refresh();
  f.time(600001);
  for (const tasks of [[agent("old", "idle"), agent("old", "idle")],
    Array.from({ length: 1001 }, (_, i) => agent(String(i), "idle"))]) {
    f.tasks(tasks);
    assert.equal((await f.tracker.stopIdleSubagents()).status, "failed");
    assert.equal(f.tracker.cleanupAvailable, false);
  }
  assert.deepEqual(f.calls, []);
});

test("invalid ancestry cannot reuse an earlier root link after observation recovers", async t => {
  const f = cleanupFixture(t);
  await f.tracker.refresh();
  f.emit({ type: "subagent.started", data: { toolCallId: "tool-old", parentId: null } });
  await f.tracker.refresh();
  f.time(600001);
  assert.equal((await f.tracker.stopIdleSubagents()).cancelled, 0);
  assert.deepEqual(f.calls, []);
});

test("subagent snapshots use live tasks, omit shells and private prompts, and preserve idle status", async () => {
  let tasks = [agent("one"), agent("two", "idle"), { type: "shell", id: "shell", status: "running" }];
  const { tracker, snapshots } = fixture(async () => ({ tasks }));
  try {
    await tracker.refresh();
    assert.equal(snapshots.at(-1).agents.length, 2);
    assert.equal(snapshots.at(-1).agents[1].status, "idle");
    assert.equal(snapshots.at(-1).agents[0].model, "actual-model");
    assert.ok(!JSON.stringify(snapshots).includes("Private"));
    tasks = [agent("two", "running")];
    await tracker.refresh();
    assert.deepEqual(snapshots.at(-1).agents.map(item => item.id), ["two"], "A fresh snapshot must remove vanished tasks");
  } finally { tracker.stop(); }
});

test("a task change during an in-flight read triggers a second authoritative snapshot", async () => {
  let resolveFirst, calls = 0;
  const { tracker, snapshots } = fixture(() => {
    calls++;
    return calls === 1 ? new Promise(resolve => { resolveFirst = resolve; }) : Promise.resolve({ tasks: [agent("new")] });
  });

  try {
    const first = tracker.refresh();
    const second = tracker.refresh();
    resolveFirst({ tasks: [agent("old")] });
    await Promise.all([first, second]);
    assert.equal(calls, 2);
    assert.equal(snapshots.at(-1).agents[0].id, "new");
  } finally { tracker.stop(); }
});

test("failed task reads report unavailable rather than a believable zero count", async () => {
  const { tracker, snapshots } = fixture(async () => { throw new Error("Runtime unavailable"); });
  try {
    await tracker.refresh();
    assert.match(snapshots.at(-1).error, /Runtime unavailable/);
  } finally { tracker.stop(); }
});

test("runtime task-change events coalesce into a live refresh without polling", { timeout: 2000 }, async () => {
  let notifyRead, calls = 0;
  const read = new Promise(resolve => { notifyRead = resolve; });
  const { tracker, snapshots, emit } = fixture(async () => {
    calls++;
    notifyRead();
    return { tasks: [agent("live")] };
  });
  try {
    emit({ type: "session.background_tasks_changed" });
    emit({ type: "session.background_tasks_changed" });
    await read;
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(calls, 1);
    assert.equal(snapshots.at(-1).runningCount, 1);
  } finally { tracker.stop(); }
});

test("late task reads cannot publish after detach", async () => {
  let resolve;
  const { tracker, snapshots } = fixture(() => new Promise(done => { resolve = done; }));
  const pending = tracker.refresh();
  tracker.stop();
  resolve({ tasks: [agent("late")] });
  await pending;
  assert.deepEqual(snapshots, []);
});

test("bounded snapshots retain active tasks ahead of historical completions", async () => {
  const tasks = [...Array.from({ length: 150 }, (_, n) => agent(String(n), "completed")), agent("active"), agent("just-stopped", "cancelled")];
  const { tracker, snapshots } = fixture(async () => ({ tasks }));
  try {
    await tracker.refresh();
    assert.equal(snapshots.at(-1).agents.length, 100);
    assert.equal(snapshots.at(-1).agents[0].id, "active");
    assert.ok(snapshots.at(-1).agents.some(item => item.id === "just-stopped"), "Recently stopped helpers must not be hidden behind old completions");
    assert.equal(snapshots.at(-1).truncated, true);
  } finally { tracker.stop(); }
});

test("ancestry uses spawning lifecycle metadata, never the journal's previous-event ID", async () => {
  const { tracker, snapshots, emit } = fixture(async () => ({
    tasks: [agent("parent"), agent("child"), agent("unobserved")]
  }));
  try {
    emit({ type: "subagent.started", parentId: "previous-journal-event",
      data: { toolCallId: "tool-parent" } });
    emit({ type: "subagent.started", parentId: "another-journal-event",
      data: { toolCallId: "tool-child", parentId: "parent" } });
    await tracker.refresh();
    const byID = Object.fromEntries(snapshots.at(-1).agents.map(item => [item.id, item]));
    assert.equal(byID.parent.parentKnown, true);
    assert.equal(byID.parent.parentAgentID, undefined, "Observed root spawns belong to the main agent");
    assert.equal(byID.child.parentAgentID, "parent");
    assert.equal(byID.child.parentKnown, true);
    assert.equal(byID.unobserved.parentKnown, false, "Already-running tasks must not be assigned an invented parent");
    await tracker.refresh();
    assert.equal(snapshots.at(-1).agents.find(item => item.id === "child").parentAgentID, "parent");
  } finally { tracker.stop(); }
});

test("cancelled retention respects the runtime completion time and detach cancels expiry", async t => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: 1000000 });
  const { tracker, snapshots } = fixture(async () => ({ tasks: [
    { ...agent("old", "cancelled"), completedAt: new Date(600000).toISOString() },
    { ...agent("recent", "cancelled"), completedAt: new Date(900000).toISOString() }
  ] }));
  await tracker.refresh();
  assert.deepEqual(snapshots.at(-1).agents.map(item => item.id), ["recent"]);
  tracker.stop();
  const count = snapshots.length;
  t.mock.timers.tick(300000);
  assert.equal(snapshots.length, count, "A detached bridge must not publish expired state");
});

test("cancelled helpers remain for five minutes without polling or resurrecting expired rows", async t => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: 1000000 });
  let tasks = [agent("stopped", "cancelled"), agent("live")], calls = 0;
  const { tracker, snapshots } = fixture(async () => { calls++; return { tasks }; });
  try {
    await tracker.refresh();
    assert.equal(snapshots.at(-1).agents.find(item => item.id === "stopped")?.status, "cancelled");
    tasks = [agent("live")];
    await tracker.refresh();
    assert.ok(snapshots.at(-1).agents.some(item => item.id === "stopped"), "Retain an observed cancellation even if the runtime removes it");
    t.mock.timers.tick(299999);
    assert.ok(snapshots.at(-1).agents.some(item => item.id === "stopped"));
    t.mock.timers.tick(1);
    assert.deepEqual(snapshots.at(-1).agents.map(item => item.id), ["live"]);
    assert.equal(calls, 2, "Expiry must not poll the runtime");
    tasks = [agent("stopped", "cancelled"), agent("live")];
    await tracker.refresh();
    assert.deepEqual(snapshots.at(-1).agents.map(item => item.id), ["live"], "Refresh must not restart the retention clock");
  } finally { tracker.stop(); }
});

test("acknowledged removal clears retained cancelled rows immediately and fences stale reads", async () => {
  let finish;
  const { tracker, snapshots } = fixture(async () => ({ tasks: [agent("removed", "cancelled"), agent("sibling")] }));
  try {
    await tracker.refresh();
    assert.equal(tracker.isRetainedCancelled("removed"), true);
    tracker.removed("removed");
    assert.equal(tracker.isRetainedCancelled("removed"), false);
    assert.deepEqual(snapshots.at(-1).agents.map(row => row.id), ["sibling"]);
    await tracker.refresh();
    assert.deepEqual(snapshots.at(-1).agents.map(row => row.id), ["sibling"]);
  } finally { tracker.stop(); }
  const stale = fixture(() => new Promise(resolve => { finish = resolve; }));
  try {
    const pending = stale.tracker.refresh();
    stale.tracker.removed("removed");
    finish({ tasks: [agent("removed", "completed"), agent("sibling")] });
    await pending;
    assert.deepEqual(stale.snapshots.at(-1).agents.map(row => row.id), ["sibling"]);
  } finally { stale.tracker.stop(); }
});

test("removal ACK corrects counts when the last published row predates task completion", async () => {
  const { tracker, snapshots } = fixture(async () => ({ tasks: [agent("recently-ended"), agent("sibling", "idle")] }));
  try {
    await tracker.refresh();
    tracker.removed("recently-ended");
    assert.equal(snapshots.at(-1).runningCount, 0);
    assert.equal(snapshots.at(-1).idleCount, 1);
    assert.deepEqual(snapshots.at(-1).agents.map(row => row.id), ["sibling"]);
  } finally { tracker.stop(); }
});
