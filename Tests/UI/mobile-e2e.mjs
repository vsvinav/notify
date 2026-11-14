import assert from "node:assert/strict";
import { createInterface } from "node:readline";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createConnection } from "node:net";
import { request as httpsRequest } from "node:https";
import { setTimeout as delay } from "node:timers/promises";

const input = createInterface({ input: process.stdin });
const configuration = JSON.parse((await input[Symbol.asyncIterator]().next()).value);
input.close();
const { directory, url, code } = configuration;
const ca = readFileSync(join(directory, "mobile", "ca.pem"));
const connection = JSON.parse(readFileSync(join(directory, "connection.json"), "utf8"));
let cookie = "", observedReply;
const agent = createConnection({ host: "127.0.0.1", port: connection.port });
const send = packet => agent.write(JSON.stringify({ ...packet, sessionID: "https-fixture" }) + "\n");
agent.on("connect", () => send({ type: "hello", token: connection.token, agent: "demo", cwd: "/fixture" }));
let buffer = "";
agent.on("data", data => {
  buffer += data;
  let end;
  while ((end = buffer.indexOf("\n")) !== -1) {
    const packet = JSON.parse(buffer.slice(0, end));
    buffer = buffer.slice(end + 1);
    if (packet.type === "welcome") {
      send({ type: "request", request: {
        id: "https-question", kind: "question", title: "Choose a fixture answer", detail: "", autoEligible: false,
        questions: [{ id: "choice", text: "Answer", multiple: false, allowFreeform: true,
          options: [{ label: "Listed choice", description: "" }] }],
      } });
    } else if (packet.type === "reply") { observedReply = packet; }
  }
});
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
  process.stdout.write(JSON.stringify({ ok: true }) + "\n");
} finally {
  agent.destroy();
}
