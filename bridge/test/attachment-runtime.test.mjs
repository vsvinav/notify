import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { once } from "node:events";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { setTimeout as delay } from "node:timers/promises";
import { CopilotClient, RuntimeConnection } from "@github/copilot-sdk";
import { scopedOptions } from "../dist/permission-options.js";
import { Bridge } from "../dist/connection.js";
import { attachCopilot } from "../dist/attachment.js";
import { formQuestions, formContent } from "../dist/protocol.js";

test("real built-in Copilot forms accept Notify Other answers without a model call", { timeout: 30_000 }, async t => {
  const root = await mkdtemp(resolve(".notify-other-"));
  const home = join(root, "home");
  await mkdir(home);
  const client = new CopilotClient({
    connection: RuntimeConnection.forStdio({
      path: execFileSync("/usr/bin/which", ["copilot"], { encoding: "utf8" }).trim(),
      args: ["--experimental"], env: { ...process.env, COPILOT_HOME: home, NODE_TLS_REJECT_UNAUTHORIZED: "1" }
    }), workingDirectory: root
  });
  t.signal.addEventListener("abort", () => { void client.forceStop(); }, { once: true });
  try {
    await client.start();
    let answered = false;
    const session = await client.createSession({
      workingDirectory: root, requestExtensions: false, enableFileHooks: false, askUserVariant: "elicitation",
      onPermissionRequest: () => ({ kind: "reject" }),
      onElicitationRequest: request => {
        assert.equal(request.elicitationSource, undefined);
        assert.ok(formQuestions(request.requestedSchema, true).every(question => question.allowFreeform));
        answered = true;
        return { action: "accept", content: formContent(request.requestedSchema, {
          choice: ["My own approach"], checks: ["Unit", "Manual review"], enabled: ["After review"], count: ["Decide later"]
        }, true) };
      }
    });
    await session.rpc.tools.initializeAndValidate();
    const result = await session.rpc.tools.execute({ name: "ask_user", arguments: {
      message: "Synthetic Notify Other answers", requestedSchema: { type: "object", properties: {
        choice: { type: "string", enum: ["A", "B"] },
        checks: { type: "array", items: { type: "string", enum: ["Unit", "Integration"] } },
        enabled: { type: "boolean" }, count: { type: "integer" }
      } }
    } });
    assert.equal(answered, true);
    for (const value of ["My own approach", "Manual review", "After review", "Decide later"]) {
      assert.ok(JSON.stringify(result).includes(value), `Runtime must preserve ${value}`);
    }
  } finally {
    await client.forceStop();
    await rm(root, { recursive: true, force: true });
  }
});

for (const scope of ["session", "project"]) test(`hot-loaded extension routes forms and ${scope} approvals through native Notify transport`, { timeout: 60_000 }, async t => {
  const root = await mkdtemp(resolve(".notify-live-"));
  const cwd = join(root, "project"), home = join(root, "copilot"), ipc = join(root, "ipc");
  await mkdir(cwd);
  await mkdir(home);
  const server = spawn(resolve("../.build/debug/NotifyTransportChecks"), [ipc, scope], { stdio: ["ignore", "pipe", "pipe"] });
  let serverError = "";
  server.stderr.on("data", chunk => { serverError += chunk; });
  const client = new CopilotClient({
    connection: RuntimeConnection.forStdio({ path: execFileSync("/usr/bin/which", ["copilot"], { encoding: "utf8" }).trim(), args: ["--experimental"],
      env: { ...process.env, COPILOT_HOME: home, NODE_TLS_REJECT_UNAUTHORIZED: "1" } }),
    workingDirectory: cwd
  });

  t.signal.addEventListener("abort", () => { void client.forceStop(); server.kill("SIGTERM"); }, { once: true });
  try {
    await Promise.race([
      once(server.stdout, "data"),
      once(server, "error").then(([error]) => { throw error; }),
      once(server, "exit").then(() => { throw new Error(`Native host exited: ${serverError}`); })
    ]);
    await client.start();
    let readPermissions = 0, shellPermissions = 0;
    const session = await client.createSession({
      workingDirectory: cwd, requestExtensions: true, enableFileHooks: false,
      onPermissionRequest: request => {
        if (request.kind === "extension-permission-access" && request.extensionName === "project:notify") {
          return { kind: "approve-once", approvedInteractively: false };
        }
        if (request.kind === "read") readPermissions++;
        if (request.kind === "shell") shellPermissions++;
        return new Promise(() => {});
      },
      onElicitationRequest: request => request.message === "Owner response"
        ? { action: "accept", content: { "0": "A" } } : new Promise(() => {})
    });
    const id = session.sessionId;
    const schema = { type: "object", properties: { "0": { type: "string", enum: ["A", "B"] } }, required: ["0"] };
    assert.deepEqual(await session.rpc.ui.elicitation({ message: "Owner response", requestedSchema: schema }),
      { action: "accept", content: { "0": "A" } });
    const extension = join(cwd, ".github", "extensions", "notify");
    await mkdir(extension, { recursive: true });
    await writeFile(join(extension, "extension.mjs"), `
import { joinSession } from "@github/copilot-sdk/extension";
import { Bridge } from ${JSON.stringify(pathToFileURL(resolve("dist/connection.js")).href)};
import { attachCopilot } from ${JSON.stringify(pathToFileURL(resolve("dist/attachment.js")).href)};
const session = await joinSession({ onPermissionRequest: () => ({ kind: "no-result" }) });
const bridge = new Bridge("copilot", process.cwd(), ${JSON.stringify(join(ipc, "connection.json"))}, session.sessionId, false);
const attached = attachCopilot(session, bridge);
await bridge.start();
await attached.recover();
`, { mode: 0o600 });
    await session.rpc.extensions.reload();
    assert.equal((await session.rpc.extensions.list()).extensions.find(e => e.name === "notify")?.status, "running");
    const response = await session.rpc.ui.elicitation({ message: "Native floating form", requestedSchema: schema });
    assert.deepEqual(response, { action: "accept", content: { "0": "B" } });
    assert.equal(session.sessionId, id);
    assert.deepEqual(await session.rpc.ui.elicitation({ message: "Owner response", requestedSchema: schema }),
      { action: "accept", content: { "0": "A" } });
    const file = join(home, "fixture.txt");
    await writeFile(file, "Notify live permission round trip");
    await session.rpc.tools.initializeAndValidate();
    const read = await session.rpc.tools.execute({ name: "view", arguments: { path: file } });
    assert.match(JSON.stringify(read), /Notify live permission round trip/);
    assert.ok(readPermissions > 0, "The native transport must actually resolve a permission, not an already-allowed read");
    const command = { name: "bash", arguments: { command: "git init --quiet notify-scoped-fixture && printf notify-scoped-fixture", description: "Create an empty disposable fixture repository", initial_wait: 30 } };
    assert.match(JSON.stringify(await session.rpc.tools.execute(command)), /notify-scoped-fixture/);
    assert.equal(shellPermissions, 1, "The first command needs a real scoped permission");
    assert.match(JSON.stringify(await session.rpc.tools.execute(command)), /notify-scoped-fixture/);
    assert.equal(shellPermissions, 1, "The same pattern must be approved by the runtime's remembered rule, not another Notify reply");
    let newSessionPrompts = 0;
    const second = await client.createSession({ workingDirectory: cwd, requestExtensions: false, enableFileHooks: false,
      onPermissionRequest: () => { newSessionPrompts++; return { kind: "reject" }; } });
    await second.rpc.permissions.locations.apply({ workingDirectory: cwd });
    await second.rpc.tools.initializeAndValidate();
    const secondResult = await second.rpc.tools.execute(command);
    if (scope === "project") {
      assert.match(JSON.stringify(secondResult), /notify-scoped-fixture/);
      assert.equal(newSessionPrompts, 0, "Project approval must persist into another session in this disposable location");
    } else {
      assert.equal(newSessionPrompts, 1, "Session approval must not escape into another session");
    }
    await delay(50);
    assert.equal(server.exitCode, null, serverError);
    assert.equal(serverError, "");
  } finally {
    await client.forceStop();
    if (server.exitCode === null && server.signalCode === null) {
      server.kill("SIGTERM");
      await once(server, "exit");
    }
    await rm(root, { recursive: true, force: true });
  }
});

test("runtime receives attached denial instructions without approving the tool", { timeout: 60_000 }, async t => {
  const root = await mkdtemp(resolve(".notify-denial-"));
  const cwd = join(root, "project"), home = join(root, "copilot");
  await mkdir(cwd);
  await mkdir(home);
  const file = join(home, "fixture.txt");
  await writeFile(file, "Must not be read");
  const client = new CopilotClient({
    connection: RuntimeConnection.forStdio({ path: execFileSync("/usr/bin/which", ["copilot"], { encoding: "utf8" }).trim(),
      env: { ...process.env, COPILOT_HOME: home, NODE_TLS_REJECT_UNAUTHORIZED: "1" } }),
    workingDirectory: cwd
  });
  t.signal.addEventListener("abort", () => { void client.forceStop(); }, { once: true });
  let attached;
  try {
    await client.start();
    const session = await client.createSession({ workingDirectory: cwd, requestExtensions: false, enableFileHooks: false,
      onPermissionRequest: () => new Promise(() => {}) });
    const bridge = new Bridge("copilot", cwd, "/missing", session.sessionId, false);
    const offered = new Promise(resolve => {
      const offer = bridge.offer.bind(bridge);
      bridge.offer = request => { offer(request); resolve(request); };
    });
    const completed = new Promise(resolve => {
      session.on(event => { if (event.type === "permission.completed") resolve(event.data); });
    });
    attached = attachCopilot(session, bridge);
    await attached.recover();
    await session.rpc.tools.initializeAndValidate();
    const executing = session.rpc.tools.execute({ name: "view", arguments: { path: file } });
    const request = await offered;
    assert.equal(request.supportsFeedback, true);
    assert.equal(await bridge.onReply({ requestID: request.id, decision: "deny",
      feedback: "  Use the public fixture.\nDo not read  this file.  " }), true);
    assert.equal((await executing).resultType, "denied");
    const result = (await completed).result;
    assert.equal(result.kind, "denied-interactively-by-user");
    assert.equal(result.feedback, "Use the public fixture.\nDo not read  this file.");
    assert.equal(bridge.pending.requests.length, 0);
  } finally {
    attached?.stop();
    await client.forceStop();
    await rm(root, { recursive: true, force: true });
  }
});

for (const scope of ["session", "project"]) test(`runtime retains exact paths and ${scope} read-tool approvals without broader path access`, { timeout: 60_000 }, async t => {
  const root = await mkdtemp(resolve(".notify-read-scope-"));
  const cwd = join(root, "project"), home = join(root, "copilot"), outside = join(root, "outside");
  for (const directory of [cwd, home, outside]) await mkdir(directory);
  const file = join(outside, "fixture.txt"), sibling = join(outside, "sibling.txt");
  await writeFile(file, "Notify scoped read fixture");
  await writeFile(sibling, "Unapproved sibling");
  const client = new CopilotClient({
    connection: RuntimeConnection.forStdio({ path: execFileSync("/usr/bin/which", ["copilot"], { encoding: "utf8" }).trim(),
      env: { ...process.env, COPILOT_HOME: home, NODE_TLS_REJECT_UNAUTHORIZED: "1" } }),
    workingDirectory: cwd
  });
  t.signal.addEventListener("abort", () => { void client.forceStop(); }, { once: true });
  try {
    await client.start();
    const prompts = [];
    const session = await client.createSession({
      workingDirectory: cwd, requestExtensions: false, enableFileHooks: false,
      onPermissionRequest: async (_request, context) => {
        const prompt = context.promptRequest;
        prompts.push(prompt);
        if (prompt.kind === "path" && prompt.paths.includes(sibling)) return { kind: "reject" };
        const id = prompt.kind === "path" ? "session-paths" : scope;
        const option = (await scopedOptions(session, prompt, cwd)).find(option => option.id === id);
        assert.ok(option, `Missing runtime ${prompt.kind} option ${id}`);
        return option.result;
      }
    });

    await session.rpc.tools.initializeAndValidate();
    const view = path => ({ name: "view", arguments: { path } });
    assert.match(JSON.stringify(await session.rpc.tools.execute(view(file))), /Notify scoped read fixture/);
    assert.deepEqual(prompts.map(prompt => prompt.kind), ["path", "read"]);
    assert.match(JSON.stringify(await session.rpc.tools.execute(view(file))), /Notify scoped read fixture/);
    assert.equal(prompts.length, 2, "The runtime must remember both scopes, not request a second approval");
    const paths = await session.rpc.permissions.paths.list();
    assert.ok(paths.sessionApprovedPaths.includes(file));
    assert.ok(!paths.directories.includes(outside), "Exact path approval must not become recursive directory access");
    assert.equal((await session.rpc.tools.execute(view(sibling))).resultType, "rejected");
    assert.equal(prompts.at(-1).kind, "path", "A read-tool approval must not approve an unoffered sibling path");
    const secondPrompts = [];
    const second = await client.createSession({
      workingDirectory: cwd, requestExtensions: false, enableFileHooks: false,
      onPermissionRequest: (_request, context) => {
        secondPrompts.push(context.promptRequest.kind);
        return context.promptRequest.kind === "path" ? { kind: "approve-once" } : { kind: "reject" };
      }
    });
    await second.rpc.permissions.locations.apply({ workingDirectory: cwd });
    await second.rpc.tools.initializeAndValidate();
    const result = await second.rpc.tools.execute(view(file));
    assert.deepEqual(secondPrompts, scope === "project" ? ["path"] : ["path", "read"]);
    if (scope === "project") assert.match(JSON.stringify(result), /Notify scoped read fixture/);
    else assert.equal(result.resultType, "rejected");
  } finally {
    await client.forceStop();
    await rm(root, { recursive: true, force: true });
  }
});
