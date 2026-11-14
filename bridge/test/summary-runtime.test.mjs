import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtemp, mkdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createSummaryClient, generateDescription } from "../dist/summary.js";

test("real summary runtime initializes an isolated tool-free session without sending a model prompt", { timeout: 30_000 }, async t => {
  const root = await mkdtemp(join(tmpdir(), "notify-summary-runtime-"));
  const home = join(root, "home"), directory = join(root, "work");
  await mkdir(home);
  await mkdir(directory);
  const client = createSummaryClient(execFileSync("/usr/bin/which", ["copilot"], { encoding: "utf8" }).trim(), home, directory);
  t.signal.addEventListener("abort", () => { void client.forceStop(); }, { once: true });
  let calls = 0;
  try {
    const result = await generateDescription({
      start: () => client.start(),
      listModels: async () => [{ id: "claude-haiku-4.5" }],
      createSession: async config => {
        const session = await client.createSession(config);
        await session.rpc.tools.initializeAndValidate();
        assert.deepEqual((await session.rpc.tools.getCurrentMetadata()).tools, []);
        const snapshot = await session.rpc.metadata.snapshot();
        assert.equal(snapshot.workingDirectory, directory);
        return { sendAndWait: async () => {
          calls++;
          return { data: { content: "Synthetic description; no model was called." } };
        } };
      },
      forceStop: () => client.forceStop()
    }, "User: Synthetic task", directory);
    assert.equal(calls, 1);
    assert.equal(result.model, "claude-haiku-4.5");
  } finally {
    await client.forceStop();
    await rm(root, { recursive: true, force: true });
  }
});
