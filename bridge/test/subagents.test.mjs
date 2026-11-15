import { test } from "node:test";
import assert from "node:assert/strict";
import { attachSubagents } from "../dist/subagents.js";

function fixture(list) {
  const snapshots = [];
  let receive;
  const tracker = attachSubagents({
    rpc: { tasks: { list } },
    on(handler) { receive = handler; return () => { receive = undefined; }; }
  }, { team(snapshot) { snapshots.push(snapshot); } });
  return { tracker, snapshots, emit: event => receive?.(event) };
}

const agent = (id, status = "running") => ({
  type: "agent", id, toolCallId: `tool-${id}`, description: `Task ${id}`, displayName: `Helper ${id}`,
  status, startedAt: "2026-11-15T01:00:00Z", agentType: "explore", prompt: "Private full prompt",
  result: "Private full result", model: "configured-model", resolvedModel: "actual-model"
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
  const tasks = [...Array.from({ length: 150 }, (_, n) => agent(String(n), "completed")), agent("active")];
  const { tracker, snapshots } = fixture(async () => ({ tasks }));
  try {
    await tracker.refresh();
    assert.equal(snapshots.at(-1).agents.length, 100);
    assert.equal(snapshots.at(-1).agents[0].id, "active");
    assert.equal(snapshots.at(-1).truncated, true);
  } finally { tracker.stop(); }
});
