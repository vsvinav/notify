import { test } from "node:test";
import assert from "node:assert/strict";
import { permissionOptions, claudePermissionOptions, selectedPermissionOption } from "../dist/permission-options.js";
import { validateReply } from "../dist/protocol.js";
import { ClaudeAgent, CopilotAgent } from "../dist/agents.js";
import { Bridge } from "../dist/connection.js";

test("command scopes preserve runtime identifiers and separate session from project persistence", () => {
  const prompt = { kind: "commands", canOfferSessionApproval: true, commandIdentifiers: ["npm test"], fullCommandText: "npm test" };
  const options = permissionOptions(prompt, "/project");
  assert.deepEqual(options.map(o => o.id), ["session", "project"]);
  assert.deepEqual(options[0].result, { kind: "approve-for-session", approval: { kind: "commands", commandIdentifiers: ["npm test"] } });
  assert.equal(options[1].result.locationKey, "/project");
  assert.equal(options[1].result.kind, "approve-for-location");
  assert.deepEqual(permissionOptions({ ...prompt, canOfferSessionApproval: false }, "/project"), []);
  assert.deepEqual(permissionOptions({ ...prompt, managedApprovalRequired: true }, "/project"), []);
  assert.deepEqual(permissionOptions({ ...prompt, requestSandboxBypass: true }, "/project"), []);
});

test("runtime URL and MCP scope restrictions are retained", () => {
  const url = permissionOptions({ kind: "url", url: "https://api.example.com/path", parentDomainPattern: "https://*.example.com" });
  assert.equal(url.find(o => o.id === "origin").result.domain, "https://api.example.com");
  assert.equal(url.find(o => o.id === "parent-domain").result.kind, "approve-for-session");
  assert.equal(url.find(o => o.id === "permanent-origin").result.domain, "https://api.example.com");
  const mcp = permissionOptions({ kind: "mcp", serverName: "tools", toolName: "lookup", canOfferServerWideApproval: false }, "/project");
  assert.ok(mcp.length > 0);
  assert.ok(mcp.every(o => o.result.approval.toolName === "lookup"));
});

test("read tool scopes are distinct from exact-path and read-only directory scopes", () => {
  const read = permissionOptions({ kind: "read", path: "/outside/file", intention: "Read fixture" }, "/project");
  assert.deepEqual(read.map(o => o.result), [
    { kind: "approve-for-session", approval: { kind: "read" } },
    { kind: "approve-for-location", approval: { kind: "read" }, locationKey: "/project" }
  ]);
  assert.match(read[0].detail, /running Copilot session/);
  assert.doesNotMatch(read[0].detail, /including resume/);
  const prompt = { kind: "path", accessKind: "read", paths: ["/outside/file"], readOnlyDirectories: ["/outside"] };
  const paths = permissionOptions(prompt, "/project");
  assert.deepEqual(paths.map(o => o.id), ["session-paths", "read-directories"]);
  assert.deepEqual(paths[0].result, { kind: "approve-for-session" });
  assert.match(paths[0].detail, /\/outside\/file/);
  assert.match(paths[0].detail, /not read-only/i);
  assert.doesNotMatch(paths[0].detail, /including resume/);
  assert.deepEqual(paths[1].result, { kind: "approve-read-only-for-session", directories: ["/outside"] });
  assert.deepEqual(permissionOptions({ ...prompt, accessKind: "write" }).map(o => o.id), ["session-paths"]);
  assert.deepEqual(permissionOptions({ ...prompt, paths: [], readOnlyDirectories: [] }), []);
});

test("exact path scope cannot be replayed after the runtime changes the requested paths", () => {
  const prompt = { kind: "path", accessKind: "read", paths: ["/outside/original"] };
  const offered = permissionOptions(prompt);
  const reply = { decision: "allow", permissionOptionID: "session-paths" };
  assert.deepEqual(selectedPermissionOption(offered, permissionOptions(prompt), reply), { kind: "approve-for-session" });
  assert.throws(() => selectedPermissionOption(offered,
    permissionOptions({ ...prompt, paths: ["/outside/replacement"] }), reply), /scope|changed/i);
});

test("permission choices cannot be forged, attached to a denial, or used automatically", () => {
  const request = { id: "r", kind: "permission", title: "Allow?", questions: [], permissionOptions: [{ id: "session", label: "Session", detail: "Scope" }] };
  assert.equal(validateReply(request, { requestID: "r", decision: "allow", permissionOptionID: "session" }), true);
  for (const reply of [
    { decision: "allow", permissionOptionID: "fake" },
    { decision: "deny", permissionOptionID: "session" },
    { decision: "allow", permissionOptionID: "session", automatic: true }
  ]) assert.equal(validateReply(request, { requestID: "r", ...reply }), false);
});

test("Claude exposes complete runtime suggestions without inventing rules or enabling a mode", async () => {
  const suggestions = [{ type: "addRules", destination: "session", behavior: "allow", rules: [{ toolName: "Bash", ruleContent: "npm test:*" }] }];
  assert.match(claudePermissionOptions(suggestions)[0].detail, /npm test:\*/);
  assert.deepEqual(claudePermissionOptions([{ type: "setMode", mode: "bypassPermissions", destination: "session" }]), []);
  let result;
  const bridge = new Bridge("claude", "/project");
  bridge.ask = async request => {
    assert.equal(request.permissionOptions[0].id, "suggested");
    assert.notEqual(request.supportsFeedback, true);
    return { decision: "allow", permissionOptionID: "suggested" };
  };
  const agent = new ClaudeAgent(bridge, "unused", undefined, undefined, ({ options }) => ({
    close() {},
    async *[Symbol.asyncIterator]() {
      result = await options.canUseTool("Bash", { command: "npm test" }, { suggestions, signal: new AbortController().signal });
    }
  }));
  await agent.send("Synthetic fixture");
  assert.deepEqual(result.updatedPermissions, suggestions);
});

for (const kind of ["commands", "path"]) test(`Copilot launcher returns the selected ${kind} scope, not approve-once`, async () => {
  const bridge = new Bridge("copilot", "/project");
  const prompt = kind === "commands"
    ? { kind, canOfferSessionApproval: true, commandIdentifiers: ["npm test"], fullCommandText: "npm test", intention: "Run tests" }
    : { kind, accessKind: "read", paths: ["/outside/fixture"] };
  let handler, failPolicy = false;
  const session = { sessionId: "fixture", on() { return () => {}; }, rpc: {
    tasks: { list: async () => ({ tasks: [] }) },
    managedSettings: { getCurrentSnapshot: async () => {
      if (failPolicy) throw new Error("Policy unavailable");
      return { source: "none", failClosed: false, managedKeys: [] };
    } },
    permissions: { locations: { resolve: async () => ({ locationKey: "/project" }) } }
  } };
  const agent = new CopilotAgent(bridge, "/unused");
  agent.client = { start: async () => {}, createSession: async config => { handler = config.onPermissionRequest; return session; } };
  await agent.start();
  const acknowledged = [];
  bridge.pending.onResolved = reply => acknowledged.push(reply);
  const handling = handler({ kind: "shell" }, { promptRequest: prompt });
  handling.catch(() => {});
  await new Promise(resolve => setImmediate(resolve));
  const request = bridge.pending.requests[0];
  const permissionOptionID = kind === "commands" ? "session" : "session-paths";
  assert.equal(request.permissionOptions[0].id, permissionOptionID);
  const reply = { requestID: request.id, decision: "allow", permissionOptionID };
  failPolicy = true;
  await assert.rejects(async () => bridge.onReply(reply), /Policy unavailable/);
  assert.equal(acknowledged.length, 0, "Failed policy rechecks must not acknowledge or dismiss a scope");
  assert.equal(bridge.pending.requests.length, 1, "The user must be able to retry a failed lookup");
  failPolicy = false;
  if (kind === "path") {
    prompt.paths = ["/outside/changed"];
    await assert.rejects(async () => bridge.onReply(reply), /scope|changed/i);
    assert.equal(acknowledged.length, 0);
    prompt.paths = ["/outside/fixture"];
  }
  assert.equal(await bridge.onReply(reply), true);
  assert.deepEqual(await handling, kind === "commands" ? {
    kind: "approve-for-session", approval: { kind: "commands", commandIdentifiers: ["npm test"] }
  } : { kind: "approve-for-session" });
});

test("Copilot launcher advertises denial feedback and preserves its trimmed instructions", async () => {
  const bridge = new Bridge("copilot", "/project");
  let handler;
  const agent = new CopilotAgent(bridge, "/unused");
  agent.client = { start: async () => {}, createSession: async config => {
    handler = config.onPermissionRequest;
    return { sessionId: "fixture", on() { return () => {}; }, rpc: { tasks: { list: async () => ({ tasks: [] }) } } };
  } };
  await agent.start();
  const handling = handler({ kind: "hook" }, {});
  await new Promise(resolve => setImmediate(resolve));
  const request = bridge.pending.requests[0];
  assert.equal(request.supportsFeedback, true);
  assert.equal(await bridge.onReply({ requestID: request.id, decision: "allow", feedback: "Do something else" }), false);
  assert.equal(await bridge.onReply({ requestID: request.id, decision: "deny", feedback: " \n " }), false);
  assert.equal(await bridge.onReply({ requestID: request.id, decision: "deny",
    feedback: "  Use a fixture instead.\nKeep  the original.  " }), true);
  assert.deepEqual(await handling, { kind: "reject", feedback: "Use a fixture instead.\nKeep  the original." });
});
