import assert from "node:assert/strict";
import { createInterface } from "node:readline";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createConnection } from "node:net";
import { request as httpsRequest } from "node:https";
import { setTimeout as delay } from "node:timers/promises";
import { randomUUID } from "node:crypto";

const input = createInterface({ input: process.stdin });
const configuration = JSON.parse((await input[Symbol.asyncIterator]().next()).value);
input.close();
const { directory, url, code } = configuration;
const ca = readFileSync(join(directory, "mobile", "ca.pem"));
const connection = JSON.parse(readFileSync(join(directory, "connection.json"), "utf8"));
let cookie = "", observedReply;
const observedControls = [];
let agent = createConnection({ host: "127.0.0.1", port: connection.port });
const send = packet => agent.write(JSON.stringify({ ...packet, sessionID: "https-fixture" }) + "\n");
const greet = () => send({ type: "hello", token: connection.token, agent: "copilot", cwd: "/fixture" });
agent.on("connect", greet);
let buffer = "";
function receiveAgent(data) {
  buffer += data;
  let end;
  while ((end = buffer.indexOf("\n")) !== -1) {
    const packet = JSON.parse(buffer.slice(0, end));
    buffer = buffer.slice(end + 1);
    if (packet.type === "welcome") {
      send({ type: "capabilities", steering: true, subagentChat: true, subagentStop: true, activityFeed: true });
      send({ type: "team", team: { agents: [{ id: "worker", name: "Worker", task: "Synthetic only", status: "idle", parentKnown: true }],
        runningCount: 0, idleCount: 1, truncated: false } });
      for (const agentID of [undefined, "worker"]) send({ type: "activity", activity: {
        id: agentID || "main", kind: "assistant", title: "Synthetic response", detail: agentID ? "Exact child response" : "Exact main response",
        status: "complete", timestamp: new Date().toISOString(), ...(agentID ? { agentID } : {})
      } });
      send({ type: "request", request: {
        id: "https-question", kind: "question", title: "Choose a fixture answer", detail: "", autoEligible: false,
        questions: [{ id: "choice", text: "Answer", multiple: false, allowFreeform: true,
          options: [{ label: "Listed choice", description: "" }] }],
      } });
    } else if (packet.type === "reply") { observedReply = packet; }
    else if (packet.type === "control") observedControls.push(packet);
  }
}
agent.on("data", receiveAgent);
function api(path, value) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify(value);
    const request = httpsRequest(new URL(path, url), {
      method: "POST", ca, rejectUnauthorized: true, timeout: 20_000,
      headers: { Origin: url, "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body), Cookie: cookie },
    }, response => {
      const chunks = [];
      response.on("data", chunk => chunks.push(chunk));
      response.on("error", reject);
      response.on("end", () => {
        try {
          for (const value of response.headers["set-cookie"] ?? []) {
            if (value.startsWith("__Host-notify=") || value.startsWith("__Host-notify-pair=")) {
              const pair = value.split(";")[0];
              const name = pair.split("=")[0];
              cookie = cookie.split("; ").filter(value => value && !value.startsWith(name + "=")).concat(pair).join("; ");
            }
          }
          resolve({ status: response.statusCode, data: JSON.parse(Buffer.concat(chunks).toString("utf8")) });
        } catch (error) { reject(error); }
      });
    });
    request.on("error", reject);
    request.on("timeout", () => request.destroy(new Error("Synthetic phone HTTPS request timed out")));
    request.end(body);
  });
}
async function until(read, predicate) {
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    const value = await read();
    if (predicate(value)) return value;
    await delay(25);
  }
  throw new Error("Synthetic phone did not reach the expected state");
}
try {
  const pairing = await api("/api/pair", { code, name: "HTTPS fixture phone" });
  assert.equal(pairing.status, 202);
  assert.equal(pairing.data.state, "pending");
  await until(() => api("/api/pair-status", {}), value => value.data.state === "accepted");
  const state = await until(() => api("/api/state", {}), value =>
    value.data.connected && value.data.requests.some(item => item.request.id === "https-question"));
  const item = state.data.requests.find(item => item.request.id === "https-question");
  const reply = { sessionID: item.sessionID, requestID: item.request.id, ticket: item.ticket,
    decision: "answer", answers: { choice: ["The exact HTTPS phone answer"] } };
  let settled = false;
  const response = api("/api/reply", reply).then(value => { settled = true; return value; });
  await until(() => observedReply, Boolean);
  assert.deepEqual(observedReply.answers, reply.answers);
  await delay(100);
  assert.equal(settled, false, "HTTPS must remain pending before the agent acknowledges");
  send({ ...observedReply, type: "resolved" });
  const result = await response;
  assert.equal(result.status, 200);
  assert.equal(result.data.ok, true);
  const duplicate = await api("/api/reply", reply);
  assert.notEqual(duplicate.status, 200, "A stale phone reply must not be replayed");
  const workspace = await until(() => api("/api/workspace", { sessionID: "https-fixture" }), value =>
    value.data.detail?.activity.length === 2);
  assert.equal(workspace.data.detail.team.agents[0].id, "worker");
  assert.equal(workspace.data.detail.activity.find(a => a.agentID === "worker").detail, "Exact child response");
  let ticket = workspace.data.sessions.find(s => s.id === "https-fixture").ticket;
  for (const [action, agentID, status] of [["queue", undefined, "queued"], ["queue", "worker", "received"], ["stop", "worker", "stopped"]]) {
    const input = { id: randomUUID(), sessionID: "https-fixture", ticket, action, text: action === "stop" ? "" : "Preserve identical native draft",
      ...(agentID ? { agentID } : {}) };
    const before = observedControls.length;
    let completed = false;
    const pending = api("/api/control", input).then(r => { completed = true; return r; });
    await until(() => observedControls.length, count => count > before);
    const actual = observedControls.at(-1);
    assert.equal(actual.agentID, agentID);
    assert.equal(actual.text, input.text);
    send({ type: "control_status", commandID: randomUUID(), status });
    if (agentID) send({ type: "control_status", commandID: actual.commandID, agentID: "wrong-agent", status });
    if (action === "stop") {
      send({ type: "team", team: { agents: [{ id: "worker", name: "Worker", task: "Synthetic only", status: "cancelled", parentKnown: true }],
        runningCount: 0, idleCount: 0, truncated: false } });
      await until(() => api("/api/workspace", { sessionID: "https-fixture" }), r =>
        r.data.detail?.team?.agents[0]?.status === "cancelled");
    }
    await delay(100);
    assert.equal(completed, false, "Wrong native command/target must not acknowledge a phone control");
    send({ type: "control_status", commandID: actual.commandID, ...(agentID ? { agentID } : {}), status, text: "Genuine fixture ACK" });
    const result = await pending;
    assert.equal(result.status, 200);
    assert.equal(result.data.commandID, actual.commandID);
    assert.equal(result.data.status, status);
    assert.equal((await api("/api/control", input)).data.commandID, actual.commandID);
    assert.equal(observedControls.length, before + 1);
    if (!agentID) {
      send({ type: "activity", activity: { id: "accepted-phone-turn", clientTurnID: actual.commandID,
        kind: "user", title: "You", detail: input.text, status: "complete", timestamp: new Date().toISOString() } });
      const resumed = await until(() => api("/api/workspace", { sessionID: "https-fixture" }), r =>
        r.data.detail && r.data.detail.ticket !== ticket && r.data.detail.activity.some(a => a.clientTurnID === actual.commandID));
      ticket = resumed.data.detail.ticket;
      send({ type: "team", team: { agents: [{ id: "worker", name: "Worker", task: "Synthetic only", status: "idle" }],
        runningCount: 0, idleCount: 0, truncated: false } });
      await until(() => api("/api/workspace", { sessionID: "https-fixture" }), r => !!r.data.detail?.team?.error);
      assert.equal((await api("/api/control", { id: randomUUID(), sessionID: "https-fixture", ticket,
        action: "queue", agentID: "worker", text: "Do not trust the old malformed team" })).status, 409);
      send({ type: "team", team: { agents: [], runningCount: 0, idleCount: 0, truncated: false, error: "Synthetic transient team failure" } });
      await until(() => api("/api/workspace", { sessionID: "https-fixture" }), r => !!r.data.detail?.team?.error);
      assert.equal((await api("/api/control", { id: randomUUID(), sessionID: "https-fixture", ticket,
        action: "queue", agentID: "worker", text: "Never redirect on team failure" })).status, 409);
      send({ type: "team", team: { agents: [{ id: "worker", name: "Worker", task: "Synthetic only", status: "idle", parentKnown: true }],
        runningCount: 0, idleCount: 1, truncated: false } });
      await until(() => api("/api/workspace", { sessionID: "https-fixture" }), r =>
        r.data.detail?.team?.agents[0]?.status === "idle" && !r.data.detail.team.error);
    }
  }
  const input = { id: randomUUID(), sessionID: "https-fixture", ticket, action: "queue", text: "Never redirect", agentID: "missing" };
  assert.equal((await api("/api/control", input)).status, 409);
  const staleStop = api("/api/control", { id: randomUUID(), sessionID: "https-fixture", ticket, action: "stop", text: "" });
  await until(() => observedControls.at(-1), c => c?.action === "stop" && !c.agentID);
  const staleCommand = observedControls.at(-1);
  send({ type: "state", state: "working" });
  await until(() => api("/api/workspace", { sessionID: "https-fixture" }), r =>
    r.data.sessions.find(s => s.id === "https-fixture")?.ticket !== ticket);
  send({ type: "control_status", commandID: staleCommand.commandID, status: "stopped", text: "Late ACK from old work" });
  assert.notEqual((await staleStop).status, 200, "A stopped ACK from an old native work generation cannot succeed");
  assert.equal((await api("/api/control", { ...input, agentID: undefined })).status, 409);
  agent.destroy();
  await until(() => api("/api/workspace", { sessionID: "https-fixture" }), r =>
    r.data.sessions.find(s => s.id === "https-fixture")?.connected === false);
  buffer = "";
  agent = createConnection({ host: "127.0.0.1", port: connection.port });
  agent.on("connect", greet);
  agent.on("data", receiveAgent);
  const reconnected = await until(() => api("/api/workspace", { sessionID: "https-fixture" }), r =>
    r.data.sessions.find(s => s.id === "https-fixture")?.connected && r.data.detail?.team?.agents[0]?.status === "idle");
  const newTicket = reconnected.data.sessions.find(s => s.id === "https-fixture").ticket;
  assert.notEqual(newTicket, ticket);
  assert.equal(reconnected.data.detail.ticket, newTicket, "Existing watch must follow only the reconnected generation");
  assert.equal((await api("/api/control", { ...input, agentID: undefined })).status, 409);
  const countBeforeDisconnect = observedControls.length;
  const lost = api("/api/control", { id: randomUUID(), sessionID: "https-fixture", ticket: newTicket, action: "queue", text: "Disconnect before ACK" });
  await until(() => observedControls.length, count => count > countBeforeDisconnect);
  agent.destroy();
  assert.notEqual((await lost).status, 200, "Socket delivery without an ACK must not succeed across disconnect");
  process.stdout.write(JSON.stringify({ ok: true }) + "\n");
} finally {
  agent.destroy();
}
