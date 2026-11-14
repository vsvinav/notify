import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { once } from "node:events";

test("terminal fallback answers demo permissions and every question without the app", { timeout: 15_000 }, async () => {
  const home = await mkdtemp(join(tmpdir(), "notify-cli-"));
  const child = spawn(process.execPath, ["dist/cli.js", "demo"], { env: { ...process.env, HOME: home }, stdio: ["pipe", "pipe", "pipe"] });
  let output = "";
  let errors = "";
  const handled = new Set<string>();
  child.stderr.on("data", data => { errors += data; });
  child.stdout.on("data", data => {
    output += data;
    for (const match of output.matchAll(/\[Needs you: ([a-f0-9]+)\] ([^\n]+)/g)) {
      if (handled.has(match[1])) continue;
      handled.add(match[1]);
      if (match[2].includes("command")) child.stdin.write(`/reply ${match[1]} deny\n`);
      else child.stdin.write(`/reply ${match[1]} {"0":["SQLite"],"1":["Unit","Integration"]}\n`);
    }
    if (output.includes("Demo question response:")) child.stdin.end();
  });
  try {
    const [code] = await once(child, "exit");
    assert.equal(code, 0, errors);
    assert.equal(handled.size, 2);
    assert.match(output, /Demo permission response: deny/);
    assert.match(output, /"1":\["Unit","Integration"\]/);
  } finally {
    if (child.exitCode === null) { child.kill("SIGTERM"); await once(child, "exit"); }
    await rm(home, { recursive: true });
  }
});
