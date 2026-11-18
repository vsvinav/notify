import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, mkdir, rm } from "node:fs/promises";
import { join, resolve } from "node:path";
import { once } from "node:events";
import { setTimeout as sleep } from "node:timers/promises";

test("production Claude hook round-trips permissions and questions through the native transport", { timeout: 20000 }, async () => {
  const home = await mkdtemp(resolve(".claude-native-"));
  const directory = join(home, "Library", "Application Support", "Notify");
  await mkdir(join(directory, "claude"), { recursive: true, mode: 0o700 });
  const children = [];
  const hookScript = resolve(process.env.NOTIFY_CLAUDE_HOOK ?? "dist/claude-hook.js");
  const native = resolve(process.env.NOTIFY_NATIVE_FIXTURE ?? "../.build/debug/NotifyTransportChecks");
  function launch(command, args, input) {
    const child = spawn(command, args, { env: { ...process.env, HOME: home }, stdio: ["pipe", "pipe", "pipe"] });
    children.push(child);
    let stdout = "", stderr = "";
    child.stdout.on("data", data => { stdout += data; });
    child.stderr.on("data", data => { stderr += data; });
    child.stdin.end(input);
    const done = once(child, "exit").then(([code]) => ({ code, stdout, stderr }));
    return { child, done, output: () => stdout, errors: () => stderr };
  }
  try {
    const server = launch(native, [directory]);
    await Promise.race([once(server.child.stdout, "data"), server.done.then(result => { throw new Error(JSON.stringify(result)); })]);
    const daemon = launch(process.execPath, [hookScript, "--serve", "native-hook", home, String(process.pid)]);
    await sleep(150);
    for (const tool of ["Bash", "AskUserQuestion"]) {
      const input = tool === "Bash" ? { command: "synthetic, never executed" }
        : { questions: [{ question: "Choose", options: [{ label: "A" }, { label: "B", description: "Native selection" }] }] };
      const hook = launch(process.execPath, [hookScript], JSON.stringify({
        session_id: "native-hook", hook_event_name: "PermissionRequest", cwd: home, tool_name: tool, tool_input: input
      }));
      const result = await hook.done;
      assert.equal(result.code, 0, result.stderr + daemon.errors());
      const response = JSON.parse(result.stdout);
      assert.equal(response.hookSpecificOutput.hookEventName, "PermissionRequest");
      assert.equal(response.hookSpecificOutput.decision.behavior, tool === "Bash" ? "deny" : "allow");
      if (tool === "AskUserQuestion") assert.deepEqual(response.hookSpecificOutput.decision.updatedInput,
        { ...input, answers: { Choose: "B" } });
    }
    const deadline = Date.now() + 3000;
    while ((server.output().match(/completion resolved /g) ?? []).length < 2 && Date.now() < deadline) await sleep(20);
    assert.equal((server.output().match(/completion resolved /g) ?? []).length, 2, server.output());
    const ended = launch(process.execPath, [hookScript], JSON.stringify({ session_id: "native-hook", hook_event_name: "SessionEnd" }));
    await ended.done;
    assert.equal((await daemon.done).code, 0);
  } finally {
    for (const child of children) if (child.exitCode === null && child.signalCode === null) {
      const exit = once(child, "exit");
      child.kill("SIGTERM");
      await exit;
    }
    await rm(home, { recursive: true, force: true });
  }
});
