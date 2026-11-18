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

test("production joined terminal streams partial activity before completion and accepts native-wire controls", { timeout: 45_000 }, async t => {
  const root = await mkdtemp(resolve(".notify-steering-"));
  const cwd = join(root, "project"), home = join(root, "home");
  await mkdir(cwd); await mkdir(home);
  execFileSync("git", ["init", "--quiet", cwd]);
  let held = 0, modelCalls = 0, peer, releaseResponse;
  const stages = {};
  const consumedAt = new Map(), userWireAt = new Map(), queueNotifications = [];
  const partial = "Local fixture partial response.";
  const packets = [], delivered = [], diagnostics = [], modelInputs = [];
  const provider = httpServer(async (request, response) => {
    let body = "";
    for await (const chunk of request) body += chunk;
    modelCalls++;
    const input = JSON.parse(body);
    modelInputs.push(input);
    const latest = [...(input.messages ?? [])].reverse().find(m => m.role === "user");
    if (JSON.stringify(latest?.content).includes("HOLD")) { held++; return; }
    response.writeHead(200, { "content-type": "text/event-stream" });
    const chunk = (delta, finish_reason = null) => `data: ${JSON.stringify({
      id: randomUUID(), object: "chat.completion.chunk", created: 0, model: "localmodel",
      choices: [{ index: 0, delta, finish_reason }]
    })}\n\n`;
    if (modelCalls === 1) {
      response.write(chunk({ role: "assistant", content: partial }));
      stages.providerPartial = performance.now();
      releaseResponse = () => {
        stages.providerComplete = performance.now();
        response.end(chunk({ content: " Finished." }) + chunk({}, "stop") + "data: [DONE]\n\n");
      };
    } else {
      response.end(chunk({ role: "assistant", content: "Local fixture response." }) + chunk({}, "stop") + "data: [DONE]\n\n");
    }
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
        if (packet.type === "activity" && packet.activity.detail === partial && packet.activity.status === "running") {
          stages.wirePartial ??= performance.now();
        }
        if (packet.type === "activity" && packet.activity.clientTurnID) {
          userWireAt.set(packet.activity.clientTurnID, performance.now());
        }
        if (packet.type === "hello") {
          assert.equal(packet.token, "fixture-secret");
          socket.write(JSON.stringify({ type: "welcome", sessionID: packet.sessionID }) + "\n");
        }
      }
    });
  });
  transport.listen(0, "127.0.0.1"); await once(transport, "listening");
  const discovery = join(home, "Library", "Application Support", "Notify");
  await mkdir(discovery, { recursive: true });
  const config = join(discovery, "connection.json");
  await writeFile(config, JSON.stringify({ port: transport.address().port, token: "fixture-secret" }), { mode: 0o600 });
  const client = new CopilotClient({
    connection: RuntimeConnection.forStdio({ path: execFileSync("/usr/bin/which", ["copilot"], { encoding: "utf8" }).trim(),
      args: ["--experimental"], env: { PATH: process.env.PATH, HOME: home, COPILOT_HOME: home, NODE_TLS_REJECT_UNAUTHORIZED: "1" } }),
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
      model: "localmodel", provider: { type: "openai", baseUrl: `http://127.0.0.1:${provider.address().port}/v1`, apiKey: "fixturekey" },
      availableTools: [], workingDirectory: cwd, requestExtensions: true, enableFileHooks: false,
      systemMessage: { mode: "replace", content: "Return the synthetic response. Do not use tools." },
      onPermissionRequest: request => request.kind === "extension-permission-access" && request.extensionName === "project:notify"
        ? { kind: "approve-once", approvedInteractively: false } : { kind: "reject", feedback: "Fixture only" }
    });
    session.on(event => {
      if (event.type === "user.message") {
        delivered.push(event.data);
        consumedAt.set(event.data.clientTurnId, performance.now());
      }
      if (event.type === "pending_messages.modified") queueNotifications.push(event.data);
      if (event.type === "assistant.message_delta" && event.data.deltaContent.includes(partial)) {
        stages.ownerPartial ??= performance.now();
      }
      if (["session.error", "assistant.message", "assistant.message_delta"].includes(event.type)) diagnostics.push(event);
    });
    const extension = join(cwd, ".github/extensions/notify");
    await mkdir(extension, { recursive: true });
    await writeFile(join(extension, "extension.mjs"),
      `await import(${JSON.stringify(pathToFileURL(resolve("dist/copilot-extension.js")).href)});\n`, { mode: 0o600 });
    await session.rpc.extensions.reload();
    diagnostics.push(await session.rpc.extensions.list());
    await waitFor(() => packets.some(p => p.type === "capabilities" && p.steering));
    function control(action, text = "", agentID, fields = {}) {
      const commandID = fields.commandID ?? randomUUID();
      peer.write(JSON.stringify({ type: "control", sessionID: session.sessionId, commandID, action, text, agentID, ...fields }) + "\n");
      return commandID;
    }
    const first = control("queue", "Use the existing helper");
    await waitFor(() => delivered.some(e => e.clientTurnId === first));
    await waitFor(() => packets.some(p => p.commandID === first && p.status === "received"));
    await waitFor(() => stages.ownerPartial);
    await waitFor(() => packets.some(p => p.type === "activity" && p.activity.clientTurnID === first));
    const partialDeadline = performance.now() + 1500;
    while (!stages.wirePartial && performance.now() < partialDeadline) await delay(20);
    t.diagnostic(`Partial stages (ms after provider): owner=${(stages.ownerPartial - stages.providerPartial).toFixed(1)}, wire=${stages.wirePartial ? (stages.wirePartial - stages.providerPartial).toFixed(1) : "missing after 1500ms"}; final withheld.`);
    assert.ok(stages.wirePartial, "Production extension must deliver running partial activity while the provider withholds completion");
    assert.equal(stages.providerComplete, undefined, "Partial activity must not wait for the final response");
    const immediateText = "IMMEDIATE_STEERING_FIXTURE", laterText = "EXPLICIT_NEXT_TURN_FIXTURE";
    const immediate = control("send", immediateText);
    await waitFor(() => packets.some(p => p.commandID === immediate && ["submitted", "received"].includes(p.status)));
    assert.equal(stages.providerComplete, undefined, "Send must not abort or complete the current model response");
    assert.equal(modelCalls, 1, "Send must wait for a safe model boundary rather than start concurrent work");
    const later = control("queue", laterText);
    await waitFor(() => packets.some(p => p.commandID === later && p.status === "queued"));
    releaseResponse();
    await waitFor(() => modelInputs.length >= 2 && delivered.some(e => e.clientTurnId === immediate));
    assert.ok(JSON.stringify(modelInputs[1].messages).includes(immediateText),
      "The next model request must consume Send without terminal intervention");
    assert.equal(JSON.stringify(modelInputs[1].messages).includes(laterText), false,
      "Explicit Queue must not be silently promoted to mid-turn steering");
    await waitFor(() => packets.some(p => p.commandID === immediate && p.status === "received"));
    await waitFor(() => delivered.some(e => e.clientTurnId === later));
    await waitFor(() => packets.some(p => p.type === "activity" && p.activity.kind === "assistant" && p.activity.status === "complete"));
    const final = packets.find(p => p.type === "activity" && p.activity.detail === partial + " Finished.");
    assert.ok(final, "Final response replaces the partial activity");
    assert.equal(final.activity.id, packets.find(p => p.type === "activity" && p.activity.detail === partial).activity.id);
    assert.equal(packets.find(p => p.type === "hello").sessionID, session.sessionId);
    const terminalTurn = randomUUID();
    await session.send({ prompt: "HOLD the original turn", clientTurnId: terminalTurn });
    await waitFor(() => held > 0);
    await waitFor(() => userWireAt.has(terminalTurn));
    t.diagnostic(`Consumed terminal prompt reached wire ${(userWireAt.get(terminalTurn) - consumedAt.get(terminalTurn)).toFixed(1)}ms after owner user.message.`);
    const queued = control("queue", "Queued follow-up");
    await waitFor(() => packets.some(p => p.commandID === queued && p.status === "queued"));
    const terminalQueued = randomUUID(), queuedText = "TERMINAL_QUEUED_FIXTURE";
    const notificationCount = queueNotifications.length;
    const submittedAt = performance.now();
    await session.send({ prompt: queuedText, mode: "enqueue", clientTurnId: terminalQueued });
    await waitFor(() => queueNotifications.length > notificationCount);
    const pending = (await session.rpc.queue.pendingItems()).items.find(item => item.displayText === queuedText);
    assert.ok(pending?.messageId, "The terminal prompt is already available as a pending queue item");
    await delay(300);
    assert.equal(consumedAt.has(terminalQueued), false, "Queued terminal input is not a consumed user.message");
    assert.equal(userWireAt.has(terminalQueued), false, "Do not misrepresent pending input as consumed chat");
    assert.ok(queueNotifications.every(data => Object.keys(data).length === 0), "Queue notifications carry no message text");
    t.diagnostic(`Queued terminal prompt visible in RPC snapshot but absent from user.message/activity after ${(performance.now() - submittedAt).toFixed(1)}ms; pending_messages.modified has empty data.`);
    const redirected = control("interrupt", "Redirect to the minimal fix");
    await waitFor(() => delivered.some(e => e.clientTurnId === redirected));
    await waitFor(() => delivered.some(e => e.clientTurnId === queued));
    await waitFor(() => userWireAt.has(terminalQueued));
    t.diagnostic(`Queued terminal prompt reached wire ${(userWireAt.get(terminalQueued) - consumedAt.get(terminalQueued)).toFixed(1)}ms after consumption.`);
    await session.send({ prompt: "HOLD another original turn" });
    await waitFor(() => held > 1);
    const stop = control("stop");
    await waitFor(() => packets.some(p => p.commandID === stop && p.status === "stopped"));
    assert.equal((await session.rpc.metadata.snapshot()).sessionId, session.sessionId);
    const child = await session.rpc.tasks.startAgent({ agentType: "general-purpose", name: "wire-child", prompt: "Synthetic child", model: "localmodel" });
    const childReady = Date.now() + 8000;
    while (!(await session.rpc.tasks.list()).tasks.some(task => task.id === child.agentId && task.status === "idle")) {
      assert.ok(Date.now() < childReady, "Synthetic child must become idle");
      await delay(20);
    }
    const childMessage = control("queue", "Synthetic follow-up", child.agentId);
    await waitFor(() => packets.some(p => p.commandID === childMessage && p.status === "received"));
    assert.ok(packets.some(p => p.type === "capabilities" && p.subagentChat && p.subagentStop));
    const activeRemove = control("remove_subagent", "", child.agentId);
    await waitFor(() => packets.some(p => p.commandID === activeRemove && p.status === "failed"));
    assert.ok(["idle", "running"].includes((await session.rpc.tasks.list()).tasks.find(task => task.id === child.agentId)?.status));
    await waitFor(() => packets.some(p => p.type === "capabilities" && p.subagentCreate && p.subagentRemove));
    const catalog = await session.rpc.agent.list({ includeBuiltInAgents: true });
    const modelCatalog = await session.rpc.model.list({ skipCache: true });
    await waitFor(() => packets.filter(p => p.type === "capabilities").at(-1)?.subagentModels?.length > 0);
    const capability = packets.filter(p => p.type === "capabilities").at(-1);
    assert.deepEqual(capability.subagentTypes, catalog.agents.map(agent => agent.id));
    assert.deepEqual(capability.subagentModels, modelCatalog.list.map(model => model.id));
    const taskType = catalog.agents.find(agent => agent.id === "task.agent.yaml");
    assert.ok(taskType, `Live runtime catalog must supply a task agent: ${JSON.stringify(capability)}`);
    const createFields = { commandID: randomUUID(), agentName: "wire-created", agentType: taskType.id };
    const created = control("create_subagent", "SYNTHETIC_MANAGEMENT_CHILD", undefined, createFields);
    control("create_subagent", "SYNTHETIC_MANAGEMENT_CHILD", undefined, createFields);
    await waitFor(() => packets.some(p => p.commandID === created && p.status === "created"));
    assert.match(packets.find(p => p.commandID === created && p.status === "created").text, /wire-created/);
    const createdTasks = (await session.rpc.tasks.list()).tasks.filter(task => task.displayName === "wire-created");
    assert.equal(createdTasks.length, 1, "Duplicate native-wire commands must create exactly one helper");
    const createdID = createdTasks[0].id;
    await waitFor(() => packets.some(p => p.type === "team" && p.team.agents.some(agent =>
      agent.id === createdID && agent.status === "idle")));
    assert.equal(packets.filter(p => p.type === "team").at(-1).team.agents.find(agent => agent.id === createdID).model, "localmodel",
      "Management creation must inherit this isolated session's local provider model");
    const beforeReplay = packets.filter(p => p.commandID === created && p.status === "created").length;
    control("create_subagent", "SYNTHETIC_MANAGEMENT_CHILD", undefined, createFields);
    await waitFor(() => packets.filter(p => p.commandID === created && p.status === "created").length > beforeReplay);
    assert.equal((await session.rpc.tasks.list()).tasks.filter(task => task.displayName === "wire-created").length, 1);
    control("create_subagent", "SYNTHETIC_MANAGEMENT_CHILD", undefined, { ...createFields, agentName: "changed" });
    await waitFor(() => packets.some(p => p.commandID === created && p.status === "failed"));
    const endCreated = control("stop", "", createdID);
    await waitFor(() => packets.some(p => p.commandID === endCreated && p.status === "stopped"));
    await waitFor(() => packets.some(p => p.type === "team" && p.team.agents.some(agent =>
      agent.id === createdID && agent.status === "cancelled")));
    const removeFields = { commandID: randomUUID() };
    const removed = control("remove_subagent", "", createdID, removeFields);
    await waitFor(() => packets.some(p => p.commandID === removed && p.status === "removed"));
    assert.equal((await session.rpc.tasks.list()).tasks.some(task => task.id === createdID), false, "Real runtime removal must be verified");
    await waitFor(() => !packets.filter(p => p.type === "team").at(-1).team.agents.some(agent => agent.id === createdID));
    const replayedRemove = packets.filter(p => p.commandID === removed && p.status === "removed").length;
    control("remove_subagent", "", createdID, removeFields);
    await waitFor(() => packets.filter(p => p.commandID === removed && p.status === "removed").length > replayedRemove);
    assert.ok(["idle", "running"].includes((await session.rpc.tasks.list()).tasks.find(task => task.id === child.agentId)?.status),
      "Creating and removing another helper must leave the unrelated child active");
    const selectedFields = { commandID: randomUUID(), agentName: "wire-selected-model", agentType: taskType.id, model: capability.subagentModels[0] };
    const selected = control("create_subagent", "SYNTHETIC_SELECTED_MODEL", undefined, selectedFields);
    await waitFor(() => packets.some(p => p.commandID === selected && p.status === "created"));
    control("create_subagent", "SYNTHETIC_SELECTED_MODEL", undefined, selectedFields);
    const selectedTasks = (await session.rpc.tasks.list()).tasks.filter(task => task.displayName === selectedFields.agentName);
    assert.equal(selectedTasks.length, 1);
    const selectedID = selectedTasks[0].id;
    await waitFor(() => packets.some(p => p.type === "team" && p.team.agents.some(agent =>
      agent.id === selectedID && agent.model === selectedFields.model && agent.status === "idle")));
    control("create_subagent", "SYNTHETIC_SELECTED_MODEL", undefined, { ...selectedFields, model: "changed" });
    await waitFor(() => packets.some(p => p.commandID === selected && p.status === "failed"));
    const unavailableModel = control("create_subagent", "NO_INFERENCE", undefined,
      { agentName: "unavailable-model", agentType: taskType.id, model: "not-in-session-catalog" });
    await waitFor(() => packets.some(p => p.commandID === unavailableModel && p.status === "failed"));
    assert.equal((await session.rpc.tasks.list()).tasks.some(task => task.displayName === "unavailable-model"), false);
    const endSelected = control("stop", "", selectedID);
    await waitFor(() => packets.some(p => p.commandID === endSelected && p.status === "stopped"));
    const removeSelected = control("remove_subagent", "", selectedID);
    await waitFor(() => packets.some(p => p.commandID === removeSelected && p.status === "removed"));
    assert.equal((await session.rpc.tasks.list()).tasks.some(task => task.id === selectedID), false);
    const helloCount = packets.filter(p => p.type === "hello").length;
    const capabilityCount = packets.filter(p => p.type === "capabilities").length;
    peer.destroy();
    await waitFor(() => packets.filter(p => p.type === "hello").length > helloCount);
    await waitFor(() => packets.filter(p => p.type === "capabilities").length > capabilityCount);
    assert.equal(packets.filter(p => p.type === "capabilities").at(-1).subagentCreate, true);
    assert.deepEqual(packets.filter(p => p.type === "capabilities").at(-1).subagentTypes, capability.subagentTypes);
    assert.deepEqual(packets.filter(p => p.type === "capabilities").at(-1).subagentModels, capability.subagentModels);
    t.diagnostic(`Verified live types ${JSON.stringify(capability.subagentTypes)}, session models ${JSON.stringify(capability.subagentModels)}, default/selected-model native-wire creation, duplicate receipts, ended removal, active rejection, and reconnect.`);
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
      id: randomUUID(), object: "chat.completion.chunk", created: 0, model: "localmodel",
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
      streaming: true, model: "localmodel",
      provider: { type: "openai", baseUrl: `http://127.0.0.1:${provider.address().port}/v1`, apiKey: "fixturekey" },
      availableTools: [], workingDirectory: cwd, enableFileHooks: false,
      systemMessage: { mode: "replace", content: "Synthetic test only. No tools." },
      onPermissionRequest: () => ({ kind: "reject", feedback: "Fixture only" })
    });
    const target = await session.rpc.tasks.startAgent({ agentType: "general-purpose", name: "fixture-target", prompt: "INITIAL_FIXTURE", model: "localmodel" });
    await waitFor(async () => (await session.rpc.tasks.list()).tasks.some(task => task.id === target.agentId && task.status === "idle"));
    assert.deepEqual(await session.rpc.tasks.sendMessage({ id: target.agentId, message: "FOLLOWUP_FIXTURE" }), { sent: true });
    await waitFor(() => requests.some(request => JSON.stringify(request.messages).includes("FOLLOWUP_FIXTURE")));
    await waitFor(async () => (await session.rpc.tasks.list()).tasks.some(task => task.id === target.agentId && task.status === "idle"));
    const sibling = await session.rpc.tasks.startAgent({ agentType: "general-purpose", name: "fixture-sibling", prompt: "HOLD_FIXTURE_SIBLING", model: "localmodel" });
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
