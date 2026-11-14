import { test } from "node:test";
import assert from "node:assert/strict";
import { ActivityFeed } from "../dist/activity.js";

const event = (type, data, agentId) => ({ type, data, agentId, id: "event", timestamp: "2026-11-13T20:00:00Z" });
test("activity correlates tool completion, exposes supplied text and excludes opaque metadata", () => {
  const sent = [];
  const feed = new ActivityFeed(entry => sent.push(entry));
  feed.receive(event("tool.execution_start", { toolCallId: "t1", toolName: "bash", arguments: { command: "npm test", secret: "not displayed" } }));
  feed.flush();
  assert.equal(sent.at(-1).detail, "command: npm test");
  feed.receive(event("tool.execution_complete", { toolCallId: "t1", success: false, error: { message: "Exit 1" } }));
  feed.flush();
  assert.equal(sent.at(-1).id, sent[0].id);
  assert.equal(sent.at(-1).status, "failed");
  assert.match(sent.at(-1).detail, /Exit 1/);
  const completion = sent.at(-1).detail;
  feed.receive(event("tool.execution_complete", { toolCallId: "t1", success: false, error: { message: "Exit 1" } }));
  feed.flush();
  assert.equal(sent.at(-1).detail, completion, "Duplicate completions must not append their output twice");
  feed.receive(event("assistant.message", { messageId: "a1", content: "Readable response", encryptedContent: "opaque" }, "child"));
  feed.flush();
  assert.equal(sent.at(-1).agentID, "child");
  assert.equal(sent.at(-1).detail, "Readable response");
  feed.stop();
});

test("empty tool-only assistant messages do not become blank conversation cards", () => {
  const sent = [];
  const feed = new ActivityFeed(entry => sent.push(entry));
  feed.receive(event("assistant.message", { messageId: "tool-only", content: "" }));
  feed.flush();
  assert.equal(sent.length, 0);
  feed.stop();
});

test("long commands leave room for failure diagnostics", () => {
  const sent = [];
  const feed = new ActivityFeed(entry => sent.push(entry));
  feed.receive(event("tool.execution_start", { toolCallId: "long", toolName: "bash", arguments: { command: "x".repeat(16000) } }));
  feed.receive(event("tool.execution_complete", { toolCallId: "long", success: false, error: { message: "Permission denied" } }));
  feed.flush();
  assert.match(sent.at(-1).detail, /Result:\nPermission denied/);
  assert.ok(sent.at(-1).detail.length <= 16000);
  feed.stop();
});

test("streaming reasoning is coalesced and bounded, final content replaces rather than duplicates", () => {
  const sent = [];
  const feed = new ActivityFeed(entry => sent.push(entry));
  for (let i = 0; i < 50; i++) feed.receive(event("assistant.reasoning_delta", { reasoningId: "r1", deltaContent: "Thinking. " }));
  assert.equal(sent.length, 0);
  feed.flush();
  assert.equal(sent.length, 1);
  assert.equal(sent[0].kind, "reasoning");
  feed.receive(event("assistant.reasoning", { reasoningId: "r1", content: "Published summary." }));
  feed.flush();
  assert.equal(sent.at(-1).detail, "Published summary.");
  assert.equal(sent.at(-1).id, sent[0].id);
  feed.receive(event("assistant.message", { messageId: "huge", content: "x".repeat(100000) }));
  feed.flush();
  assert.ok(sent.at(-1).detail.length <= 16000);
  assert.match(sent.at(-1).detail, /truncated/);
  feed.stop();
});

test("streamed whitespace preserves words and code indentation", () => {
  const sent = [];
  const feed = new ActivityFeed(entry => sent.push(entry));
  for (const deltaContent of ["Run", " ", "tests", "\n", "  ", "next"]) {
    feed.receive(event("assistant.message_delta", { messageId: "stream", deltaContent }));
  }
  feed.flush();
  assert.equal(sent.at(-1).detail, "Run tests\n  next");
  feed.stop();
});
