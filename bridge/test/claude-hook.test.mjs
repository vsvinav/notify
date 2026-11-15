import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer, createConnection } from "node:net";
import { mkdir, mkdtemp, writeFile, rm, stat, appendFile, readdir } from "node:fs/promises";
import { resolve, join } from "node:path";
import { once } from "node:events";
import { setTimeout as sleep } from "node:timers/promises";
import { createHash } from "node:crypto";

const hookScript = resolve(process.env.NOTIFY_CLAUDE_HOOK ?? "dist/claude-hook.js");
async function until(read, message, timeout = 7000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    const value = await read();
    if (value) return value;
    await sleep(20);
  }
  assert.fail(message);
}

async function fixture(t) {
  const home = await mkdtemp(resolve(".ch-"));
  const directory = join(home, "Library", "Application Support", "Notify");
  await mkdir(join(directory, "claude"), { recursive: true, mode: 0o700 });
  const frames = [], sockets = new Set(), children = new Set(), daemonPIDs = new Set();
  const server = createServer(socket => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    socket.on("error", () => {});
    let buffer = "";
    socket.on("data", chunk => {
      buffer += chunk;
      let end;
      while ((end = buffer.indexOf("\n")) >= 0) {
        const frame = JSON.parse(buffer.slice(0, end)); buffer = buffer.slice(end + 1);
        frames.push({ ...frame, socket });
        if (frame.type === "hello") {
          daemonPIDs.add(frame.pid);
          socket.write(JSON.stringify({ type: "welcome", sessionID: frame.sessionID }) + "\n");
        }
      }
    });
  });
  server.listen(0, "127.0.0.1"); await once(server, "listening");
  await writeFile(join(directory, "connection.json"), JSON.stringify({ port: server.address().port, token: "synthetic-only" }), { mode: 0o600 });
  const session = "fixture-session";
  const transcript = join(home, "transcript.jsonl");
  await writeFile(transcript, "");
  function start(args, input) {
    const child = spawn(process.execPath, [hookScript, ...args], {
      env: { ...process.env, HOME: home }, stdio: ["pipe", "pipe", "pipe"]
    });
    children.add(child);
    let stdout = "", stderr = "";
    child.stdout.on("data", data => { stdout += data; });
    child.stderr.on("data", data => { stderr += data; });
    child.stdin.end(input);
    const done = once(child, "exit").then(([code, signal]) => ({ code, signal, stdout, stderr }));
    return { child, done };
  }
  const event = (name, extra = {}) => ({
    session_id: session, hook_event_name: name, cwd: home, transcript_path: transcript, ...extra
  });
  const hook = (name, extra) => start([], JSON.stringify(event(name, extra)));
  const serve = (ownerPID = process.pid) => start(["--serve", session, home, String(ownerPID), transcript]);
  const wait = (predicate, message) => until(() => frames.find(predicate), message);
  const reply = (frame, value) => frame.socket.write(JSON.stringify({
    type: "reply", sessionID: frame.sessionID, requestID: frame.request.id, ...value
  }) + "\n");
  t.after(async () => {
    for (const child of children) if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
    for (const pid of daemonPIDs) {
      try { process.kill(pid, "SIGTERM"); } catch {}
    }
    for (const socket of sockets) socket.destroy();
    await new Promise(resolve => server.close(resolve));
    await sleep(100);
    await rm(home, { recursive: true, force: true });
  });
  const socketPath = join(directory, "claude", createHash("sha256").update(session).digest("hex").slice(0, 16) + ".sock");
  return { home, directory, frames, hook, serve, wait, reply, transcript, daemonPIDs, event, socketPath };
}

test("a hook loaded into an existing session attaches on its next event", { timeout: 12000 }, async t => {
  const f = await fixture(t);
  assert.equal((await f.hook("UserPromptSubmit").done).code, 0);
  const hello = await f.wait(x => x.type === "hello", "next event must bootstrap a daemon");
  assert.equal(hello.agent, "claude");
  const caps = await f.wait(x => x.type === "capabilities", "capabilities missing");
  assert.equal(caps.steering, false);
  assert.equal(caps.subagentStop, false);
  assert.equal((await f.hook("SessionStart").done).code, 0);
  await sleep(150);
  assert.equal(f.daemonPIDs.size, 1, "reload must not replace the original session daemon");
});

test("production hook delivers exact supplied scope and denial output", { timeout: 12000 }, async t => {
  const f = await fixture(t); f.serve();
  await f.wait(x => x.type === "hello", "daemon did not register");
  const suggestions = [{ type: "addRules", rules: [{ toolName: "Bash", ruleContent: "npm test" }], behavior: "allow", destination: "session" }];
  const permission = f.hook("PermissionRequest", { tool_name: "Bash", tool_input: { command: "npm test" }, permission_suggestions: suggestions });
  const request = await f.wait(x => x.type === "request", "permission missing");
  assert.equal(request.request.permissionOptions?.[0]?.id, "suggested");
  f.reply(request, { decision: "allow", permissionOptionID: "suggested" });
  const result = await permission.done;
  assert.equal(result.code, 0);
  assert.deepEqual(JSON.parse(result.stdout), { hookSpecificOutput: { hookEventName: "PermissionRequest",
    decision: { behavior: "allow", updatedInput: { command: "npm test" }, updatedPermissions: suggestions } } });
  await f.wait(x => x.type === "resolved" && x.requestID === request.request.id && !x.cancelled, "missing delivery receipt");
  const denied = f.hook("PermissionRequest", { tool_name: "Bash", tool_input: { command: "echo no" } });
  const next = await f.wait(x => x.type === "request" && x.request.id !== request.request.id, "second permission missing");
  f.reply(next, { decision: "deny", feedback: "Use the test fixture instead." });
  assert.deepEqual(JSON.parse((await denied.done).stdout).hookSpecificOutput.decision,
    { behavior: "deny", message: "Use the test fixture instead." });
});

test("hook questions preserve free text and multiple selections", { timeout: 12000 }, async t => {
  const f = await fixture(t); f.serve();
  await f.wait(x => x.type === "hello", "daemon did not register");
  const input = { questions: [
    { question: "Which?", multiSelect: true, options: [{ label: "A", description: "First" }, { label: "B", description: "Second" }] },
    { question: "Why?", options: [{ label: "Yes" }, { label: "No" }] }
  ] };
  const call = f.hook("PermissionRequest", { tool_name: "AskUserQuestion", tool_input: input });
  const request = await f.wait(x => x.type === "request", "question missing");
  assert.equal(request.request.kind, "question");
  f.reply(request, { decision: "answer", answers: { "0": ["A", "B"], "1": ["Custom reason"] } });
  assert.deepEqual(JSON.parse((await call.done).stdout).hookSpecificOutput.decision,
    { behavior: "allow", updatedInput: { ...input, answers: { "Which?": "A, B", "Why?": "Custom reason" } } });
});

test("a cancelled hook retires only itself; unrelated events and reconnect cannot approve it", { timeout: 15000 }, async t => {
  const f = await fixture(t); f.serve();
  await f.wait(x => x.type === "hello", "daemon did not register");
  const a = f.hook("PermissionRequest", { tool_name: "Bash", tool_input: { command: "A" } });
  const first = await f.wait(x => x.type === "request", "first missing");
  const b = f.hook("PermissionRequest", { tool_name: "Read", tool_input: { file_path: "B" } });
  const second = await f.wait(x => x.type === "request" && x.request.id !== first.request.id, "second missing");
  await f.hook("Notification").done;
  await f.hook("SubagentStop", { agent_id: "unrelated" }).done;
  assert.equal(f.frames.some(x => x.type === "resolved"), false, "unrelated events must not settle permissions");
  a.child.kill("SIGTERM"); await a.done;
  await f.wait(x => x.type === "resolved" && x.requestID === first.request.id && x.cancelled, "dead hook must cancel its request");
  second.socket.destroy();
  await until(() => f.frames.filter(x => x.type === "hello").length === 2, "daemon must reconnect");
  const replay = await f.wait(x => x.type === "request" && x.request.id === second.request.id && x.socket !== second.socket, "live request must replay");
  f.reply(replay, { decision: "allow" });
  assert.equal(JSON.parse((await b.done).stdout).hookSpecificOutput.decision.behavior, "allow");
});

test("transcript follower keeps split UTF-8 lines and reports only public main-thread activity", { timeout: 12000 }, async t => {
  const f = await fixture(t); f.serve();
  await f.wait(x => x.type === "hello", "daemon did not register");
  const entry = JSON.stringify({ type: "assistant", uuid: "split", message: { content: [{ type: "text", text: "Hello café" }] } });
  const bytes = Buffer.from(entry + "\n");
  const split = bytes.indexOf(Buffer.from("é")) + 1;
  await appendFile(f.transcript, bytes.subarray(0, split));
  await sleep(1200);
  await appendFile(f.transcript, bytes.subarray(split));
  const activity = await f.wait(x => x.type === "activity" && x.activity.id === "split", "split line was lost");
  assert.equal(activity.activity.detail, "Hello café");
  await f.hook("SubagentStart", { agent_id: "child-1", agent_type: "Explore", prompt: "private prompt" }).done;
  const team = await f.wait(x => x.type === "team" && x.team.agents.length, "documented subagent identity not published");
  assert.equal(team.team.agents[0].id, "child-1");
  assert.equal(team.team.agents[0].task, "");
  assert.equal((await stat(join(f.directory, "claude"))).mode & 0o077, 0);
  assert.equal((await stat(f.socketPath)).mode & 0o077, 0);
  await appendFile(f.transcript, JSON.stringify({ type: "custom-title", customTitle: "Real title" }) + "\n");
  await f.wait(x => x.type === "metadata" && x.title === "Real title" && x.sourceSessionID === "fixture-session", "title record was lost");
});

test("an approval is not resolved before hook stdout acknowledgement", { timeout: 12000 }, async t => {
  const f = await fixture(t); f.serve();
  await f.wait(x => x.type === "hello", "daemon did not register");
  const socket = createConnection(f.socketPath);
  t.after(() => socket.destroy());
  await once(socket, "connect");
  socket.write(JSON.stringify(f.event("PermissionRequest", { tool_name: "Read", tool_input: { file_path: "fixture" } })) + "\n");
  const request = await f.wait(x => x.type === "request", "permission missing");
  const response = once(socket, "data");
  f.reply(request, { decision: "allow" });
  await response;
  await sleep(50);
  assert.equal(f.frames.some(x => x.type === "resolved"), false);
  socket.destroy();
  await f.wait(x => x.type === "resolved" && x.requestID === request.request.id && x.cancelled, "delivery loss must cancel, not claim success");
});

test("concurrent startup retains one owner and SessionEnd cleans daemon resources", { timeout: 12000 }, async t => {
  const f = await fixture(t);
  await Promise.all(Array.from({ length: 8 }, () => f.hook("SessionStart").done));
  await f.wait(x => x.type === "hello", "daemon did not register");
  await sleep(100);
  assert.equal(f.daemonPIDs.size, 1);
  const permission = f.hook("PermissionRequest", { tool_name: "Read", tool_input: { file_path: "fixture" } });
  const request = await f.wait(x => x.type === "request", "permission missing");
  await f.hook("SessionEnd").done;
  assert.equal((await permission.done).stdout, "", "session end must not approve or deny into the ended runtime");
  await until(async () => (await readdir(join(f.directory, "claude"))).length === 0, "daemon socket and owner lock must be cleaned");
  assert.equal(f.frames.some(x => x.type === "resolved" && x.requestID === request.request.id && !x.cancelled), false);
});

test("an oversized or wrong-session hook frame cannot register an actionable permission", { timeout: 12000 }, async t => {
  const f = await fixture(t); f.serve();
  await f.wait(x => x.type === "hello", "daemon did not register");
  for (const data of [
    JSON.stringify(f.event("PermissionRequest", { session_id: "wrong", tool_name: "Read", tool_input: {} })) + "\n",
    "x".repeat(1_048_577)
  ]) {
    const socket = createConnection(f.socketPath);
    socket.on("error", () => {}); socket.resume();
    await once(socket, "connect");
    const closed = new Promise(resolve => socket.once("close", resolve));
    socket.write(data);
    await closed;
  }
  assert.equal(f.frames.some(x => x.type === "request"), false);
});

test("a dead owner ends its daemon and a killed daemon can reconnect without stale approvals", { timeout: 20000 }, async t => {
  const f = await fixture(t);
  const owner = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
  t.after(() => { if (owner.exitCode === null && owner.signalCode === null) owner.kill("SIGTERM"); });
  const first = f.serve(owner.pid);
  await f.wait(x => x.type === "hello", "daemon did not register");
  const pending = f.hook("PermissionRequest", { tool_name: "Read", tool_input: { file_path: "fixture" } });
  await f.wait(x => x.type === "request", "permission missing");
  first.child.kill("SIGKILL"); await first.done;
  assert.equal((await pending.done).stdout, "", "a daemon crash must return no permission decision");
  const second = f.serve(owner.pid);
  await until(() => f.frames.filter(x => x.type === "hello").length === 2, "stale socket and owner lock must recover");
  assert.equal(f.frames.filter(x => x.type === "request").length, 1, "crashed hook must not replay its stale approval");
  const exited = once(owner, "exit"); owner.kill("SIGTERM"); await exited;
  assert.equal((await second.done).code, 0, "daemon must exit when its owner exits");
  assert.deepEqual(await readdir(join(f.directory, "claude")), []);
});

test("an auto-bootstrapped daemon outlives the transient hook command shell", { timeout: 12000 }, async t => {
  const f = await fixture(t);
  const quote = value => "'" + value.replace(/'/g, "'\\''") + "'";
  const shell = spawn("/bin/sh", ["-c", `${quote(process.execPath)} ${quote(hookScript)}; :`], {
    env: { ...process.env, HOME: f.home }, stdio: ["pipe", "ignore", "pipe"]
  });
  shell.stdin.end(JSON.stringify(f.event("SessionStart")));
  const [code] = await once(shell, "exit");
  assert.equal(code, 0);
  const hello = await f.wait(x => x.type === "hello", "hook did not attach");
  await sleep(5500);
  assert.equal(hello.socket.destroyed, false, "watchdog must follow Claude's parent process, not the exited hook shell");
  await f.hook("SessionEnd").done;
});
