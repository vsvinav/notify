import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer as httpServer } from "node:http";
import { createServer as netServer } from "node:net";
import { once } from "node:events";
import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, writeFile, rm } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { setTimeout as delay } from "node:timers/promises";
import { CopilotClient, RuntimeConnection } from "@github/copilot-sdk";

test("joined terminal accepts native-wire steering and stop with a local synthetic provider", { timeout: 45_000 }, async t => {
  const root = await mkdtemp(resolve(".notify-steering-"));
  const cwd = join(root, "project"), home = join(root, "home");
  await mkdir(cwd); await mkdir(home);
  execFileSync("git", ["init", "--quiet", cwd]);
  let held = 0, modelCalls = 0, peer;
  const packets = [], delivered = [], diagnostics = [];
  const provider = httpServer(async (request, response) => {
    let body = "";
    for await (const chunk of request) body += chunk;
    modelCalls++;
    const input = JSON.parse(body);
    const latest = [...(input.messages ?? [])].reverse().find(m => m.role === "user");
    if (JSON.stringify(latest?.content).includes("HOLD")) { held++; return; }
    response.writeHead(200, { "content-type": "text/event-stream" });
    const chunk = (delta, finish_reason = null) => `data: ${JSON.stringify({
      id: randomUUID(), object: "chat.completion.chunk", created: 0, model: "gpt-4",
      choices: [{ index: 0, delta, finish_reason }]
    })}\n\n`;
    response.end(chunk({ role: "assistant", content: "Local fixture response." }) + chunk({}, "stop") + "data: [DONE]\n\n");
  });

  provider.listen(0, "127.0.0.1"); await once(provider, "listening");
  const transport = netServer(socket => {
    peer = socket;
    let buffer = "";
    socket.on("data", chunk => {
      buffer += chunk;
      let end;
      while ((end = buffer.indexOf("\n")) >= 0) {
        const packet = JSON.parse(buffer.slice(0, end)); buffer = buffer.slice(end + 1);
        packets.push(packet);
        if (packet.type === "hello") {
          assert.equal(packet.token, "fixture-secret");
          socket.write(JSON.stringify({ type: "welcome", sessionID: packet.sessionID }) + "\n");
        }
      }
    });
  });
  transport.listen(0, "127.0.0.1"); await once(transport, "listening");
  const config = join(root, "connection.json");
  await writeFile(config, JSON.stringify({ port: transport.address().port, token: "fixture-secret" }), { mode: 0o600 });
  const client = new CopilotClient({
    connection: RuntimeConnection.forStdio({ path: execFileSync("/usr/bin/which", ["copilot"], { encoding: "utf8" }).trim(),
      args: ["--experimental"], env: { ...process.env, COPILOT_HOME: home, NODE_TLS_REJECT_UNAUTHORIZED: "1" } }),
    workingDirectory: cwd
  });
  t.signal.addEventListener("abort", () => { void client.forceStop(); peer?.destroy(); provider.closeAllConnections(); }, { once: true });
  async function waitFor(predicate) {
    const until = Date.now() + 8000;
    while (!predicate()) {
      if (Date.now() >= until) throw new Error(`Fixture wait timed out; calls=${modelCalls}, diagnostics=${JSON.stringify(diagnostics)}, last packets: ${JSON.stringify(packets.slice(-6))}`);
      await delay(20);
    }
  }
  try {
    await client.start();
    const session = await client.createSession({
      streaming: true,
      model: "gpt-4", provider: { type: "openai", baseUrl: `http://127.0.0.1:${provider.address().port}/v1`, apiKey: "fixture" },
      availableTools: [], workingDirectory: cwd, requestExtensions: true, enableFileHooks: false,
      systemMessage: { mode: "replace", content: "Return the synthetic response. Do not use tools." },
      onPermissionRequest: request => request.kind === "extension-permission-access" && request.extensionName === "project:notify"
        ? { kind: "approve-once", approvedInteractively: false } : { kind: "reject", feedback: "Fixture only" }
    });
    session.on(event => {
      if (event.type === "user.message") delivered.push(event.data);
      if (["session.error", "assistant.message", "assistant.message_delta"].includes(event.type)) diagnostics.push(event);
    });
    const extension = join(cwd, ".github/extensions/notify");
    await mkdir(extension, { recursive: true });
    await writeFile(join(extension, "extension.mjs"), `
import { joinSession } from "@github/copilot-sdk/extension";
import { Bridge } from ${JSON.stringify(pathToFileURL(resolve("dist/connection.js")).href)};
import { attachSteering } from ${JSON.stringify(pathToFileURL(resolve("dist/steering.js")).href)};
import { ActivityFeed } from ${JSON.stringify(pathToFileURL(resolve("dist/activity.js")).href)};
const session = await joinSession({ onPermissionRequest: () => ({ kind: "no-result" }) });
const bridge = new Bridge("copilot", process.cwd(), ${JSON.stringify(config)}, session.sessionId, false);
attachSteering(session, bridge);
const feed = new ActivityFeed(entry => bridge.activity(entry));
session.on(event => feed.receive(event));
bridge.enableActivity();
await bridge.start();
`, { mode: 0o600 });
    await session.rpc.extensions.reload();
    diagnostics.push(await session.rpc.extensions.list());
    await waitFor(() => packets.some(p => p.type === "capabilities" && p.steering));
    function control(action, text = "", agentID) {
      const commandID = randomUUID();
      peer.write(JSON.stringify({ type: "control", sessionID: session.sessionId, commandID, action, text, agentID }) + "\n");
      return commandID;
    }
    const first = control("queue", "Use the existing helper");
    await waitFor(() => delivered.some(e => e.clientTurnId === first));
    await waitFor(() => packets.some(p => p.commandID === first && p.status === "received"));
    await waitFor(() => packets.some(p => p.type === "activity" && p.activity.kind === "assistant" && p.activity.status === "complete"));
    assert.ok(packets.some(p => p.type === "activity" && p.activity.detail === "Local fixture response."),
      "Real streamed response must reach the activity bridge");
    assert.equal(packets.find(p => p.type === "hello").sessionID, session.sessionId);
    await session.send({ prompt: "HOLD the original turn" });
    await waitFor(() => held > 0);
    const queued = control("queue", "Queued follow-up");
    await waitFor(() => packets.some(p => p.commandID === queued && p.status === "queued"));
    const redirected = control("interrupt", "Redirect to the minimal fix");
    await waitFor(() => delivered.some(e => e.clientTurnId === redirected));
    await waitFor(() => delivered.some(e => e.clientTurnId === queued));
    await session.send({ prompt: "HOLD another original turn" });
    await waitFor(() => held > 1);
    const stop = control("stop");
    await waitFor(() => packets.some(p => p.commandID === stop && p.status === "stopped"));
    assert.equal((await session.rpc.metadata.snapshot()).sessionId, session.sessionId);
    const child = await session.rpc.tasks.startAgent({ agentType: "general-purpose", name: "wire-child", prompt: "Synthetic child", model: "gpt-4" });
    const childReady = Date.now() + 8000;
    while (!(await session.rpc.tasks.list()).tasks.some(task => task.id === child.agentId && task.status === "idle")) {
      assert.ok(Date.now() < childReady, "Synthetic child must become idle");
      await delay(20);
    }
    const childMessage = control("queue", "Synthetic follow-up", child.agentId);
    await waitFor(() => packets.some(p => p.commandID === childMessage && p.status === "received"));
    assert.ok(packets.some(p => p.type === "capabilities" && p.subagentChat && p.subagentStop));
    const stopChild = control("stop", "", child.agentId);
    await waitFor(() => packets.some(p => p.commandID === stopChild && p.status === "stopped"));
    assert.equal((await session.rpc.metadata.snapshot()).sessionId, session.sessionId, "Child controls preserve the original main owner");
    assert.ok(modelCalls > 0, "Only the local synthetic provider should be called");
  } finally {
    await client.forceStop();
    peer?.destroy();
    transport.close(); provider.closeAllConnections(); provider.close();
    await rm(root, { recursive: true, force: true });
  }
});

test("installed runtime messages and cancels only the exact synthetic child", { timeout: 45_000 }, async t => {
  const root = await mkdtemp(resolve(".notify-child-steering-"));
  const cwd = join(root, "project"), home = join(root, "home");
  await mkdir(cwd); await mkdir(home);
  const requests = [];
  const provider = httpServer(async (request, response) => {
    let body = "";
    for await (const chunk of request) body += chunk;
    const input = JSON.parse(body);
    requests.push(input);
    if (JSON.stringify(input.messages).includes("HOLD_FIXTURE")) return;
    response.writeHead(200, { "content-type": "text/event-stream" });
    const chunk = (delta, finish_reason = null) => `data: ${JSON.stringify({
      id: randomUUID(), object: "chat.completion.chunk", created: 0, model: "gpt-4",
      choices: [{ index: 0, delta, finish_reason }]
    })}\n\n`;
    response.end(chunk({ role: "assistant", content: "Synthetic child reply." }) + chunk({}, "stop") + "data: [DONE]\n\n");
  });
  provider.listen(0, "127.0.0.1"); await once(provider, "listening");
  const client = new CopilotClient({
    connection: RuntimeConnection.forStdio({
      path: execFileSync("/usr/bin/which", ["copilot"], { encoding: "utf8" }).trim(), args: ["--experimental"],
      env: { PATH: process.env.PATH, HOME: home, COPILOT_HOME: home, NODE_TLS_REJECT_UNAUTHORIZED: "1" }
    }),
    workingDirectory: cwd
  });
  t.signal.addEventListener("abort", () => { void client.forceStop(); provider.closeAllConnections(); }, { once: true });
  async function waitFor(predicate) {
    const until = Date.now() + 8000;
    while (!await predicate()) {
      if (Date.now() >= until) throw new Error(`Child fixture timed out; local model calls=${requests.length}`);
      await delay(20);
    }
  }
  try {
    await client.start();
    const session = await client.createSession({
      streaming: true, model: "gpt-4",
      provider: { type: "openai", baseUrl: `http://127.0.0.1:${provider.address().port}/v1`, apiKey: "fixture" },
      availableTools: [], workingDirectory: cwd, enableFileHooks: false,
      systemMessage: { mode: "replace", content: "Synthetic test only. No tools." },
      onPermissionRequest: () => ({ kind: "reject", feedback: "Fixture only" })
    });
    const target = await session.rpc.tasks.startAgent({ agentType: "general-purpose", name: "fixture-target", prompt: "INITIAL_FIXTURE", model: "gpt-4" });
    await waitFor(async () => (await session.rpc.tasks.list()).tasks.some(task => task.id === target.agentId && task.status === "idle"));
    assert.deepEqual(await session.rpc.tasks.sendMessage({ id: target.agentId, message: "FOLLOWUP_FIXTURE" }), { sent: true });
    await waitFor(() => requests.some(request => JSON.stringify(request.messages).includes("FOLLOWUP_FIXTURE")));
    await waitFor(async () => (await session.rpc.tasks.list()).tasks.some(task => task.id === target.agentId && task.status === "idle"));
    const sibling = await session.rpc.tasks.startAgent({ agentType: "general-purpose", name: "fixture-sibling", prompt: "HOLD_FIXTURE_SIBLING", model: "gpt-4" });
    await session.send({ prompt: "HOLD_FIXTURE_MAIN" });
    await waitFor(() => requests.some(request => JSON.stringify(request.messages).includes("HOLD_FIXTURE_MAIN")));
    assert.deepEqual(await session.rpc.tasks.sendMessage({ id: target.agentId, message: "HOLD_FIXTURE_TARGET" }), { sent: true });
    await waitFor(async () => (await session.rpc.tasks.list()).tasks.some(task => task.id === target.agentId && task.status === "running"));
    assert.deepEqual(await session.rpc.tasks.sendMessage({ id: target.agentId, message: "STEER_RUNNING_FIXTURE" }), { sent: true });
    assert.deepEqual(await session.rpc.tasks.cancel({ id: target.agentId }), { cancelled: true });
    const tasks = (await session.rpc.tasks.list()).tasks;
    assert.equal(tasks.find(task => task.id === target.agentId)?.status, "cancelled");
    assert.equal(tasks.find(task => task.id === sibling.agentId)?.status, "running");
    assert.equal((await session.rpc.metadata.snapshot()).sessionId, session.sessionId);
    assert.equal((await session.rpc.tasks.sendMessage({ id: target.agentId, message: "NO_RESURRECTION_FIXTURE" })).sent, false);
    t.diagnostic(`Verified idle/running sendMessage and exact-target cancel with ${requests.length} local synthetic model calls.`);
  } finally {
    await client.forceStop();
    provider.closeAllConnections(); provider.close();
    await rm(root, { recursive: true, force: true });
  }
});
