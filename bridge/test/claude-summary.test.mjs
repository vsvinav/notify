import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { resolve, join } from "node:path";
import * as summary from "../dist/summarize-claude.js";

test("Claude excerpts include real user records, exclude child/tool content and remain bounded", async () => {
  assert.equal(typeof summary.readClaudeExcerpt, "function");
  const root = await mkdtemp(resolve(".claude-summary-"));
  try {
    const path = join(root, "transcript.jsonl");
    await writeFile(path, [
      { type: "user", message: { content: "Original user goal" } },
      { type: "assistant", isSidechain: true, message: { content: "PRIVATE CHILD" } },
      { type: "user", message: { content: [{ type: "tool_result", content: "SECRET TOOL OUTPUT" }] } },
      { type: "assistant", message: { content: [{ type: "thinking", thinking: "PRIVATE REASONING" }, { type: "text", text: "Progress" }] } }
    ].map(x => JSON.stringify(x)).join("\n") + "\n");
    const excerpt = await summary.readClaudeExcerpt(path);
    assert.match(excerpt, /User: Original user goal/);
    assert.match(excerpt, /Assistant: Progress/);
    assert.doesNotMatch(excerpt, /PRIVATE|SECRET/);
    assert.ok(excerpt.length <= 12000);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("Claude summaries cannot run tools or hooks and always close their owned query", async () => {
  assert.equal(typeof summary.generateClaudeDescription, "function");
  let options, closed = 0;
  const makeQuery = input => {
    options = input.options;
    return {
      async *[Symbol.asyncIterator]() {
        yield { type: "assistant", message: { model: "claude-haiku-4-5-20251001", content: [{ type: "text", text: "A short summary." }] } };
      },
      close() { closed++; }
    };
  };
  const result = await summary.generateClaudeDescription("User: goal", process.cwd(), "/fixture/claude", makeQuery);
  assert.equal(result.text, "A short summary.");
  assert.deepEqual(options.tools, []);
  assert.deepEqual(options.settingSources, []);
  assert.equal(options.settings.disableAllHooks, true);
  assert.equal(options.persistSession, false);
  assert.equal(options.permissionMode, "default");
  assert.equal((await options.canUseTool("Read", {})).behavior, "deny");
  assert.equal(closed, 1);
});

test("a summary timeout actively cancels an unresponsive query", { timeout: 2000 }, async () => {
  assert.equal(typeof summary.generateClaudeDescription, "function");
  let closed = 0, controller;
  const makeQuery = input => {
    controller = input.options.abortController;
    return { [Symbol.asyncIterator]() { return { next: () => new Promise(() => {}) }; }, close() { closed++; } };
  };
  await assert.rejects(summary.generateClaudeDescription("User: goal", process.cwd(), "/fixture/claude", makeQuery, 20), /timed out/);
  assert.equal(controller.signal.aborted, true);
  assert.equal(closed, 1);
});
