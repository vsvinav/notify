import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setupCopilot } from "../dist/setup.js";

test("extension installation is private, repeatable, and never overwrites another extension", async () => {
  const root = await mkdtemp(join(tmpdir(), "notify-setup-"));
  try {
    const path = await setupCopilot(root);
    assert.equal((await stat(path)).mode & 0o077, 0);
    assert.match(await readFile(path, "utf8"), /copilot-extension\.js/);
    assert.equal(await setupCopilot(root), path);
    await writeFile(path, "// user's existing extension");
    await assert.rejects(setupCopilot(root), /Not replacing/);
    assert.equal(await readFile(path, "utf8"), "// user's existing extension");
  } finally { await rm(root, { recursive: true, force: true }); }
});
