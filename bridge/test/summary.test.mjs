import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const summaryModule = () => import("../dist/summary.js");

test("summary runtime preserves the existing macOS account credential source", async () => {
  const { createSummaryClient } = await summaryModule();
  const client = createSummaryClient("/usr/bin/true", "/tmp/notify-home", "/tmp/notify-work");
  assert.equal(client.buildRuntimeEnv().COPILOT_DISABLE_KEYTAR, process.env.COPILOT_DISABLE_KEYTAR,
    "SDK defaults must not disable the existing Keychain login");
});

test("summarizer keeps conversation text bounded and excludes tool payloads", async () => {
  const { readExcerpt } = await summaryModule();
  const root = await mkdtemp(join(tmpdir(), "notify-summary-test-"));
  const path = join(root, "events.jsonl");
  try {
    const events = [
      { type: "user.message", data: { content: "Fix the login form" } },
      { type: "tool.execution_complete", data: { content: "SECRET TOOL OUTPUT" } },
      { type: "assistant.message", data: { content: "Updating validation", toolRequests: [{ arguments: "SECRET ARGS" }] } },
      { type: "assistant.message", agentId: "other-agent", data: { content: "UNRELATED AGENT" } },
      { type: "assistant.message", data: { content: "x".repeat(14000) } }
    ];
    await writeFile(path, events.map(e => JSON.stringify(e)).join("\n") + "\n");
    const excerpt = await readExcerpt(path);
    assert.ok(excerpt.length <= 12000);
    assert.ok(excerpt.includes("Fix the login form"), "retain the task's intent alongside recent text");
    assert.ok(!excerpt.includes("SECRET"));
    assert.ok(!excerpt.includes("UNRELATED"));
    const link = join(root, "link.jsonl");
    await symlink(path, link);
    await assert.rejects(readExcerpt(link), /symbolic|regular|ELOOP/i);
    await writeFile(path, "broken json\n");
    await assert.rejects(readExcerpt(path), /transcript/i);
    const large = [
      { type: "user.message", data: { content: "Original task" } },
      { type: "tool.execution_complete", data: { content: "z".repeat(600000) } },
      { type: "assistant.message", data: { content: "Recent progress after a large tool result" } }
    ].map(e => JSON.stringify(e)).join("\n") + "\n";
    await writeFile(path, large);
    const bounded = await readExcerpt(path);
    assert.match(bounded, /Original task/);
    assert.match(bounded, /Recent progress/);
  } finally { await rm(root, { recursive: true, force: true }); }
});

function fakeClient(models, response = "Fixes account login validation.") {
  const state = { sends: 0, stopped: 0, config: undefined };
  return {
    state,
    start: async () => {},
    listModels: async () => models,
    createSession: async config => {
      state.config = config;
      return { sendAndWait: async () => { state.sends++; return { data: { content: response } }; } };
    },
    forceStop: async () => { state.stopped++; }
  };
}

test("summary uses only available Haiku with no tools and shuts down its owned client", async () => {
  const { generateDescription } = await summaryModule();
  const client = fakeClient([{ id: "expensive-model", billing: { multiplier: 30 } },
    { id: "claude-haiku-4.5", billing: { multiplier: 1 } }]);
  const result = await generateDescription(client, "User: Fix account login", "/tmp/notify-test");
  assert.equal(result.text, "Fixes account login validation.");
  assert.equal(result.model, "claude-haiku-4.5");
  assert.deepEqual(client.state.config.availableTools, []);
  assert.deepEqual(client.state.config.allowedModels, ["claude-haiku-4.5"]);
  assert.equal(client.state.config.enableConfigDiscovery, false);
  assert.equal(client.state.config.enableFileHooks, false);
  assert.equal(client.state.sends, 1);
  assert.equal(client.state.stopped, 1);
});

test("no Haiku, rejected model output and timeouts fail visibly without fallback", async () => {
  const { generateDescription } = await summaryModule();
  const missing = fakeClient([{ id: "claude-sonnet", billing: { multiplier: 1 } }]);
  await assert.rejects(generateDescription(missing, "User: task", "/tmp/notify-test"), /Haiku/);
  assert.equal(missing.state.sends, 0);
  assert.equal(missing.state.stopped, 1);
  const empty = fakeClient([{ id: "claude-haiku-4.5" }], "");
  await assert.rejects(generateDescription(empty, "User: task", "/tmp/notify-test"), /empty/i);
  assert.equal(empty.state.stopped, 1);
  const stalled = fakeClient([{ id: "claude-haiku-4.5" }]);
  stalled.start = () => new Promise(() => {});
  await assert.rejects(generateDescription(stalled, "User: task", "/tmp/notify-test", 20), /timed out/i);
  assert.equal(stalled.state.stopped, 1);
});
