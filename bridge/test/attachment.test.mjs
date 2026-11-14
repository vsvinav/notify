import { test } from "node:test";
import assert from "node:assert/strict";
import { Bridge } from "../dist/connection.js";
import { attachCopilot } from "../dist/attachment.js";

const question = (id, elicitationSource) => ({
  type: "elicitation.requested",
  data: { requestId: id, elicitationSource, message: "Choose", requestedSchema: {
    type: "object", properties: { choice: { type: "string", enum: ["A", "B"] } }, required: ["choice"]
  } }
});
const tick = () => new Promise(resolve => setImmediate(resolve));
function harness(respond) {
  let listener;
  const bridge = new Bridge("copilot", "/project", "/missing", "session", false);
  const acknowledged = [], errors = [];
  bridge.pending.onResolved = reply => acknowledged.push(reply);
  bridge.error = error => errors.push(String(error));
  const session = {
    on: callback => { listener = callback; return () => {}; },
    rpc: { ui: { handlePendingElicitation: respond }, permissions: { pendingRequests: async () => ({ items: [] }) } }
  };
  const attachment = attachCopilot(session, bridge);
  return { bridge, session, attachment, emit: event => listener(event), acknowledged, errors };
}

test("attached replies remain pending until the original runtime accepts them", async () => {
  let accept, calls = 0;
  const h = harness(() => { calls++; return new Promise(resolve => { accept = resolve; }); });
  h.emit(question("one"));
  await tick();
  const reply = { requestID: "one", decision: "answer", answers: { choice: ["B"] } };
  const sending = h.bridge.onReply(reply);
  assert.equal(h.bridge.pending.requests.length, 1);
  assert.equal(h.acknowledged.length, 0);
  assert.equal(await h.bridge.onReply(reply), false);
  h.emit({ type: "elicitation.completed", data: { requestId: "one" } });
  assert.equal(h.acknowledged.length, 0, "a completion event cannot preempt the acceptance result");
  accept({ success: true });
  assert.equal(await sending, true);
  assert.equal(calls, 1);
  assert.equal(h.acknowledged[0].decision, "answer");
  assert.equal(h.bridge.pending.requests.length, 0);
  h.attachment.stop();
});

test("terminal-first completion removes the floating request without sending a reply", async () => {
  let calls = 0;
  const h = harness(async () => { calls++; return { success: true }; });
  h.emit(question("one"));
  await tick();
  h.emit({ type: "elicitation.completed", data: { requestId: "one" } });
  assert.equal(h.acknowledged[0].cancelled, true);
  assert.equal(await h.bridge.onReply({ requestID: "one", decision: "deny" }), false);
  assert.equal(calls, 0);
  h.attachment.stop();
});

test("live chat title changes are forwarded independently of activity", async () => {
  const h = harness(async () => ({ success: true }));
  const titles = [];
  h.bridge.setTitle = title => titles.push(title);
  h.emit({ type: "session.title_changed", data: { title: "Fix account login" } });
  await tick();
  assert.deepEqual(titles, ["Fix account login"]);
  const activity = [];
  h.bridge.setState = (state, text) => activity.push(text);
  h.emit({ type: "assistant.turn_start", data: {} });
  h.emit({ type: "assistant.message_delta", data: { deltaContent: "Working on the fix" } });
  h.emit({ type: "assistant.message_delta", data: { deltaContent: "." } });
  await tick();
  assert.deepEqual(activity, ["Copilot is working", "Copilot is responding"]);
  h.attachment.stop();
});

test("runtime rejection is cancellation, while delivery failures retain a retryable prompt", async () => {
  let fail = true;
  const h = harness(async () => {
    if (fail) throw new Error("transport unavailable");
    return { success: false };
  });
  h.emit(question("one"));
  await tick();
  const reply = { requestID: "one", decision: "answer", answers: { choice: ["B"] } };
  await assert.rejects(h.bridge.onReply(reply), /transport unavailable/);
  assert.equal(h.bridge.pending.requests.length, 1);
  assert.equal(h.acknowledged.length, 0);
  fail = false;
  await h.bridge.onReply(reply);
  assert.equal(h.acknowledged[0].cancelled, true);
  assert.equal(h.bridge.pending.requests.length, 0);
  h.attachment.stop();
});

test("invalid forms never reach the runtime and stopping never denies original requests", async () => {
  let calls = 0;
  const h = harness(async () => { calls++; return { success: true }; });
  h.emit(question("one", "strict-mcp-form"));
  await tick();
  assert.equal(await h.bridge.onReply({ requestID: "one", decision: "answer", answers: { choice: ["C"] } }), false);
  h.attachment.stop();
  h.bridge.stop();
  assert.equal(calls, 0);
  assert.equal(h.acknowledged[0].cancelled, true);
});

test("agent-initiated form Other answers reach the original session unchanged", async () => {
  let response;
  const h = harness(async value => { response = value; return { success: true }; });
  h.emit(question("custom"));
  await tick();
  assert.equal(h.bridge.pending.requests[0].questions[0].allowFreeform, true);
  assert.equal(await h.bridge.onReply({ requestID: "custom", decision: "answer", answers: { choice: ["My own approach"] } }), true);
  assert.deepEqual(response.result, { action: "accept", content: { choice: "My own approach" } });
  h.attachment.stop();
});

test("completion during policy lookup or pending recovery cannot resurrect a request", async () => {
  const h = harness(async () => ({ success: true }));
  let finishPolicy;
  h.session.rpc.managedSettings = { getCurrentSnapshot: () => new Promise(resolve => { finishPolicy = resolve; }) };
  h.emit({ type: "permission.requested", data: { requestId: "read",
    permissionRequest: { kind: "read", path: "/project/file.ts" } } });
  h.emit({ type: "permission.completed", data: { requestId: "read" } });
  finishPolicy(null);
  await tick();
  assert.equal(h.bridge.pending.requests.length, 0);
  let finishRecovery;
  h.session.rpc.permissions.pendingRequests = () => new Promise(resolve => { finishRecovery = resolve; });
  const recovery = h.attachment.recover();
  h.emit({ type: "permission.completed", data: { requestId: "old" } });
  finishRecovery({ items: [{ requestId: "old", request: { kind: "read", path: "/project/old.ts" } }] });
  await recovery;
  assert.equal(h.bridge.pending.requests.length, 0);
  h.attachment.stop();
});

test("broader automatic approval is policy gated and never applies to questions or recovered prompts", async () => {
  const h = harness(async () => ({ success: true }));
  const approvals = [];
  let policy = { source: "none", failClosed: false, managedKeys: [] };
  h.session.rpc.managedSettings = { getCurrentSnapshot: async () => policy };
  h.session.rpc.permissions.handlePendingPermissionRequest = async value => { approvals.push(value); return { success: true }; };
  h.emit({ type: "permission.requested", data: { requestId: "shell", permissionRequest: { kind: "shell", command: "touch file" } } });
  await tick();
  assert.equal(h.bridge.pending.requests[0].sessionAutoEligible, true);
  assert.equal(h.bridge.pending.requests[0].autoEligible, false);
  assert.equal(await h.bridge.onReply({ requestID: "shell", decision: "allow", automatic: true }), false);
  await h.bridge.onReply({ requestID: "shell", decision: "allow", automatic: true, approvalScope: "session" });
  assert.equal(approvals.length, 1);
  assert.equal(approvals[0].result.approvedInteractively, false);
  h.emit({ type: "permission.requested", data: { requestId: "changed", permissionRequest: { kind: "write", path: "/project/file" } } });
  await tick();
  policy = { source: "managed", failClosed: false, managedKeys: ["permissions"] };
  await assert.rejects(h.bridge.onReply({ requestID: "changed", decision: "allow", automatic: true, approvalScope: "session" }), /policy/i);
  assert.equal(approvals.length, 1);
  policy = { source: "none", failClosed: false, managedKeys: [] };
  for (const [id, permissionRequest] of [
    ["managed", { kind: "shell", managedApprovalRequired: true }],
    ["sandbox", { kind: "shell", requestSandboxBypass: true }],
    ["access", { kind: "extension-permission-access" }]
  ]) {
    h.emit({ type: "permission.requested", data: { requestId: id, permissionRequest } });
    await tick();
    assert.notEqual(h.bridge.pending.requests.find(r => r.id === id).sessionAutoEligible, true);
  }
  h.emit(question("question"));
  await tick();
  assert.notEqual(h.bridge.pending.requests.find(r => r.id === "question").sessionAutoEligible, true);
  h.session.rpc.permissions.pendingRequests = async () => ({ items: [{ requestId: "old", request: { kind: "shell" } }] });
  await h.attachment.recover();
  assert.notEqual(h.bridge.pending.requests.find(r => r.id === "old").sessionAutoEligible, true);
  h.attachment.stop();
});

test("live permissions recover omitted prompt metadata for the exact pending request", async () => {
  const h = harness(async () => ({ success: true }));
  const prompt = { kind: "commands", canOfferSessionApproval: true, commandIdentifiers: ["npm test"], fullCommandText: "npm test", intention: "Run tests" };
  h.session.rpc.managedSettings = { getCurrentSnapshot: async () => ({ source: "none", failClosed: false, managedKeys: [] }) };
  h.session.rpc.permissions.locations = { resolve: async () => ({ locationKey: "/project" }) };
  h.session.rpc.permissions.pendingRequests = async () => ({ items: [
    { requestId: "unrelated", request: { ...prompt, commandIdentifiers: ["different command"] } },
    { requestId: "live-scope", request: prompt }
  ] });
  const calls = [];
  h.session.rpc.permissions.handlePendingPermissionRequest = async value => { calls.push(value); return { success: true }; };
  h.emit({ type: "permission.requested", data: { requestId: "live-scope", permissionRequest: { kind: "shell", fullCommandText: "npm test" } } });
  await tick();
  const request = h.bridge.pending.requests[0];
  assert.deepEqual(request.permissionOptions.map(option => option.id), ["session", "project"]);
  assert.equal(JSON.parse(request.detail).intention, "Run tests");
  assert.equal(await h.bridge.onReply({ requestID: "live-scope", decision: "allow", permissionOptionID: "session" }), true);
  assert.deepEqual(calls[0], { requestId: "live-scope", result: { kind: "approve-for-session", approval: { kind: "commands", commandIdentifiers: ["npm test"] } } });
  h.attachment.stop();
});

test("failed live prompt lookup reports unavailable choices without inventing scopes", async () => {
  const h = harness(async () => ({ success: true }));
  h.session.rpc.managedSettings = { getCurrentSnapshot: async () => ({ source: "none", failClosed: false, managedKeys: [] }) };
  h.session.rpc.permissions.pendingRequests = async () => { throw new Error("pending lookup unavailable"); };
  h.emit({ type: "permission.requested", data: { requestId: "lookup-error", permissionRequest: { kind: "shell", fullCommandText: "npm test" } } });
  await tick();
  assert.deepEqual(h.bridge.pending.requests[0].permissionOptions, []);
  assert.match(h.errors.join("\n"), /approval choices.*pending lookup unavailable/i);
  h.attachment.stop();
});

test("scoped choices reach the runtime unchanged and policy changes block persistence", async () => {
  const h = harness(async () => ({ success: true }));
  const prompt = { kind: "commands", canOfferSessionApproval: true, commandIdentifiers: ["npm test"], fullCommandText: "npm test", intention: "Run tests" };
  let policy = { source: "none", failClosed: false, managedKeys: [] };
  const calls = [];
  h.session.rpc.managedSettings = { getCurrentSnapshot: async () => policy };
  h.session.rpc.permissions.locations = { resolve: async () => ({ locationKey: "/project" }) };
  h.session.rpc.permissions.pendingRequests = async () => ({ items: [{ requestId: "scope", request: prompt }] });
  h.session.rpc.permissions.handlePendingPermissionRequest = async value => { calls.push(value); return { success: true }; };
  await h.attachment.recover();
  const request = h.bridge.pending.requests[0];
  assert.deepEqual(request.permissionOptions?.map(o => o.id), ["session", "project"]);
  assert.equal(await h.bridge.onReply({ requestID: "scope", decision: "allow", permissionOptionID: "unknown" }), false);
  assert.equal(await h.bridge.onReply({ requestID: "scope", decision: "allow", permissionOptionID: "project", automatic: true }), false);
  policy = { source: "managed", failClosed: false, managedKeys: ["permissions"] };
  await assert.rejects(h.bridge.onReply({ requestID: "scope", decision: "allow", permissionOptionID: "project" }), /scope|policy/i);
  assert.equal(calls.length, 0);
  policy = { source: "none", failClosed: false, managedKeys: [] };
  prompt.commandIdentifiers = ["rm"];
  await assert.rejects(h.bridge.onReply({ requestID: "scope", decision: "allow", permissionOptionID: "project" }), /scope|changed/i);
  assert.equal(calls.length, 0);
  prompt.commandIdentifiers = ["npm test"];
  await h.bridge.onReply({ requestID: "scope", decision: "allow", permissionOptionID: "project" });
  assert.deepEqual(calls[0].result, { kind: "approve-for-location", approval: { kind: "commands", commandIdentifiers: ["npm test"] }, locationKey: "/project" });
  assert.equal(h.acknowledged[0].permissionOptionID, "project");
  h.attachment.stop();
});

test("path approval rechecks the exact pending paths before acknowledging the runtime reply", async () => {
  const h = harness(async () => ({ success: true }));
  let prompt = { kind: "path", accessKind: "read", paths: ["/outside/file"], readOnlyDirectories: ["/outside"] };
  const calls = [];
  h.session.rpc.managedSettings = { getCurrentSnapshot: async () => ({ source: "none", failClosed: false, managedKeys: [] }) };
  h.session.rpc.permissions.locations = { resolve: async () => ({ locationKey: "/project" }) };
  h.session.rpc.permissions.pendingRequests = async () => ({ items: [{ requestId: "path", request: prompt }] });
  h.session.rpc.permissions.handlePendingPermissionRequest = async value => { calls.push(value); return { success: true }; };
  await h.attachment.recover();
  assert.deepEqual(h.bridge.pending.requests[0].permissionOptions.map(o => o.id), ["session-paths", "read-directories"]);
  const reply = { requestID: "path", decision: "allow", permissionOptionID: "session-paths" };
  prompt = { ...prompt, paths: ["/outside/changed"] };
  await assert.rejects(h.bridge.onReply(reply), /scope|changed/i);
  assert.equal(calls.length, 0);
  assert.equal(h.acknowledged.length, 0);
  prompt = { ...prompt, paths: ["/outside/file"] };
  assert.equal(await h.bridge.onReply(reply), true);
  assert.deepEqual(calls, [{ requestId: "path", result: { kind: "approve-for-session" } }]);
  assert.equal(h.acknowledged[0].permissionOptionID, "session-paths");
  h.attachment.stop();
});

for (const recovered of [false, true]) test(`${recovered ? "recovered" : "live"} permission denial forwards instructions only after accepted delivery`, async () => {
  const h = harness(async () => ({ success: true }));
  const calls = [];
  let fail = true;
  const prompt = { kind: "hook", toolName: "fixture" };
  h.session.rpc.permissions.handlePendingPermissionRequest = async value => {
    if (fail) throw new Error("delivery unavailable");
    calls.push(value);
    return { success: true };
  };
  if (recovered) {
    h.session.rpc.permissions.pendingRequests = async () => ({ items: [{ requestId: "deny", request: prompt }] });
    await h.attachment.recover();
  } else {
    h.emit({ type: "permission.requested", data: { requestId: "deny", permissionRequest: prompt, promptRequest: prompt } });
    await tick();
  }
  assert.equal(h.bridge.pending.requests[0].supportsFeedback, true);
  const reply = { requestID: "deny", decision: "deny", feedback: "  Keep the original.\nUse  a copy.  " };
  await assert.rejects(h.bridge.onReply(reply), /delivery unavailable/);
  assert.equal(h.acknowledged.length, 0);
  assert.equal(h.bridge.pending.requests.length, 1);
  fail = false;
  assert.equal(await h.bridge.onReply(reply), true);
  assert.deepEqual(calls, [{ requestId: "deny", result: { kind: "reject", feedback: "Keep the original.\nUse  a copy." } }]);
  assert.equal(h.acknowledged.length, 1);
  h.attachment.stop();
});
