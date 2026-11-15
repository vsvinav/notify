import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile, rm, stat, symlink, readdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { setupCopilot, setupClaude } from "../dist/setup.js";

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

test("Claude installer preserves user settings atomically, quotes shell paths, and is idempotent", async () => {
  const root = await mkdtemp(resolve(".claude-setup-"));
  const previous = process.env.CLAUDE_CONFIG_DIR;
  process.env.CLAUDE_CONFIG_DIR = root;
  try {
    const path = join(root, "settings.json");
    const original = { permissions: { deny: ["Read(.env)"] }, custom: { keep: true },
      hooks: { PreToolUse: [{ matcher: "Bash", hooks: [{ type: "command", command: "echo user-hook" }] }] } };
    await writeFile(path, JSON.stringify(original), { mode: 0o644 });
    assert.equal(await setupClaude(root), path);
    const installed = JSON.parse(await readFile(path, "utf8"));
    assert.deepEqual(installed.permissions, original.permissions);
    assert.deepEqual(installed.custom, original.custom);
    assert.deepEqual(installed.hooks.PreToolUse[0], original.hooks.PreToolUse[0]);
    assert.ok(installed.hooks.PostToolUseFailure);
    const hook = installed.hooks.PermissionRequest[0].hooks[0];
    assert.match(hook.command, /^exec '/);
    assert.equal(hook.timeout, 120);
    const before = await readFile(path, "utf8");
    await setupClaude(root);
    assert.equal(await readFile(path, "utf8"), before);
    assert.equal((await stat(path)).mode & 0o077, 0);
    assert.deepEqual(await readdir(root), ["settings.json"]);
  } finally {
    if (previous === undefined) delete process.env.CLAUDE_CONFIG_DIR;
    else process.env.CLAUDE_CONFIG_DIR = previous;
    await rm(root, { recursive: true, force: true });
  }
});

test("Claude installer refuses malformed settings and symlinks without destroying their contents", async () => {
  const root = await mkdtemp(resolve(".claude-setup-"));
  const previous = process.env.CLAUDE_CONFIG_DIR;
  process.env.CLAUDE_CONFIG_DIR = root;
  try {
    const path = join(root, "settings.json");
    for (const text of ["null", "[]", '{"hooks":[]}', '{"hooks":{"PreToolUse":null}}', "{invalid"]) {
      await writeFile(path, text, { mode: 0o600 });
      await assert.rejects(setupClaude(root));
      assert.equal(await readFile(path, "utf8"), text);
    }
    const other = join(root, "other.json");
    await writeFile(other, "{}");
    await rm(path);
    await symlink(other, path);
    await assert.rejects(setupClaude(root), /regular|symbolic|symlink/i);
    assert.equal(await readFile(other, "utf8"), "{}");
  } finally {
    if (previous === undefined) delete process.env.CLAUDE_CONFIG_DIR;
    else process.env.CLAUDE_CONFIG_DIR = previous;
    await rm(root, { recursive: true, force: true });
  }
});
