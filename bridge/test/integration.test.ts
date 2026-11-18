import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, stat, rm } from "node:fs/promises";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { connect } from "node:net";
import { once } from "node:events";
import { Bridge } from "../dist/connection.js";

test("native transport authenticates and returns exact permission and question replies", { timeout: 30_000 }, async () => {
  const root = await mkdtemp(join(tmpdir(), "notify-wire-"));
  const server = spawn(resolve(process.env.NOTIFY_NATIVE_FIXTURE ?? "../.build/debug/NotifyTransportChecks"), [root], { stdio: ["ignore", "pipe", "pipe"] });
  let stderr = "";
  let stdout = "";
  server.stdout.on("data", chunk => { stdout += chunk; });
  server.stderr.on("data", chunk => { stderr += chunk; });
  try {
    await Promise.race([
      once(server.stdout, "data"),
      once(server, "error").then(([error]) => { throw error; }),
      once(server, "exit").then(() => { throw new Error(`Server exited: ${stderr}`); })
    ]);
    const config = JSON.parse(await readFile(join(root, "connection.json"), "utf8"));
    assert.equal((await stat(join(root, "connection.json"))).mode & 0o077, 0);
    const bad = connect({ host: "127.0.0.1", port: config.port });
    await once(bad, "connect");
    bad.write(JSON.stringify({ type: "hello", sessionID: "bad", agent: "demo", cwd: root, token: "wrong" }) + "\n");
    await once(bad, "close");
    const socket = connect({ host: "127.0.0.1", port: config.port });
    await once(socket, "connect");
    const lines: Record<string, unknown>[] = [];
    let buffer = "";
    let next: (() => void) | undefined;
    socket.on("data", chunk => {
      buffer += chunk;
      let index: number;
      while ((index = buffer.indexOf("\n")) >= 0) {
        lines.push(JSON.parse(buffer.slice(0, index)));
        buffer = buffer.slice(index + 1);
      }
      next?.(); next = undefined;
    });
    const receive = async () => {
      if (!lines.length) await new Promise<void>(resolve => { next = resolve; });
      return lines.shift()!;
    };
    socket.write(JSON.stringify({ type: "hello", token: config.token, sessionID: "test-session", agent: "demo", cwd: root }) + "\n");
    assert.equal((await receive()).type, "welcome");
    const request = { id: "permission-1", kind: "permission", title: "Allow?", detail: "demo", autoEligible: false, questions: [] };
    const frame = JSON.stringify({ type: "request", sessionID: "test-session", request }) + "\n";
    socket.write(frame.slice(0, 19)); socket.write(frame.slice(19));
    const deny = await receive();
    assert.equal(deny.sessionID, "test-session");
    assert.equal(deny.requestID, "permission-1");
    assert.equal(deny.decision, "deny");
    socket.write(JSON.stringify({ type: "request", sessionID: "test-session", request: {
      ...request, id: "question-1", kind: "question", questions: [
        { id: "0", text: "Choose", multiple: false, allowFreeform: false, options: [{ label: "B", description: "" }] }
      ]
    } }) + "\n");
    const answer = await receive();
    assert.equal(answer.requestID, "question-1");
    assert.deepEqual(answer.answers, { "0": ["B"] });
    socket.end();
    const bridge = new Bridge("demo", root, join(root, "connection.json"));
    try {
      await bridge.start();
      const result = await bridge.ask({
        kind: "permission", title: "Bridge round trip", detail: "No execution", autoEligible: false, questions: []
      });
      assert.equal(result.decision, "deny");
      assert.equal(bridge.pending.requests.length, 0);
      const choice = await bridge.ask({
        kind: "question", title: "Bridge choices", detail: "", autoEligible: false,
        questions: [{ id: "0", text: "Choose", multiple: false, allowFreeform: false, options: [{ label: "B", description: "" }] }]
      });
      assert.deepEqual(choice.answers, { "0": ["B"] });
      const deadline = Date.now() + 2000;
      while (!stdout.includes(` ${choice.requestID}\n`) && Date.now() < deadline) {
        await new Promise(resolve => setTimeout(resolve, 10));
      }
      assert.ok(stdout.includes(`completion resolved ${result.requestID}\n`),
        `Permission completion must not echo the native reply type: ${stdout}`);
      assert.ok(stdout.includes(`completion resolved ${choice.requestID}\n`),
        `Question completion must not echo the native reply type: ${stdout}`);
    } finally { bridge.stop(); }
  } finally {
    if (server.pid && server.exitCode === null) {
      server.kill("SIGTERM");
      await once(server, "exit");
    }
    await rm(root, { recursive: true });
  }
});
