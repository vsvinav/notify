import { createInterface } from "node:readline";
import { appendFileSync, mkdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { createConnection } from "node:net";

let directory, agent, requests = [], lastReply, step = 0;
const status = {
  url: "https://fixture.local:9443", setupURL: "http://fixture.local:9444",
  fingerprint: Array(32).fill("AB").join(":"), devices: [{ id: "phone", name: "Fixture phone", online: true, pushEnabled: true }],
  pendingPairingIDs: [],
};
const emit = value => process.stdout.write(JSON.stringify(value) + "\n");
const record = value => appendFileSync(join(directory, "events.jsonl"), JSON.stringify(value) + "\n", { mode: 0o600 });
const sendAgent = value => agent.write(JSON.stringify({ ...value, sessionID: "mobile-fixture" }) + "\n");
function phoneReply(id, requestID, ticket, answer) {
  emit({ type: "reply", id, sessionID: "mobile-fixture", requestID, ticket,
    decision: "answer", answers: { choice: [answer] } });
}
for await (const line of createInterface({ input: process.stdin })) {
  const command = JSON.parse(line);
  if (command.type === "start") {
    directory = command.directory;
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    record({ type: "environment", tls: process.env.NODE_TLS_REJECT_UNAUTHORIZED });
    const connection = JSON.parse(readFileSync(join(dirname(directory), "connection.json"), "utf8"));
    agent = createConnection({ host: "127.0.0.1", port: connection.port }, () =>
      sendAgent({ type: "hello", token: connection.token, agent: "copilot", cwd: "/fixture" }));
    let buffer = "";
    agent.on("data", data => {
      buffer += data;
      let end;
      while ((end = buffer.indexOf("\n")) !== -1) {
        const packet = JSON.parse(buffer.slice(0, end));
        buffer = buffer.slice(end + 1);
        if (packet.type === "welcome") {
          sendAgent({ type: "capabilities", steering: true, subagentChat: true, subagentStop: true });
          for (const id of ["custom", "fixed"]) {
            sendAgent({ type: "request", request: { id, kind: "question", title: "Pick an approach", detail: "",
              autoEligible: false, questions: [{ id: "choice", text: "Approach", multiple: false,
                allowFreeform: id === "custom", options: [{ label: "Listed answer", description: "" }] }] } });
          }
        } else if (packet.type === "reply") {
          lastReply = packet;
          record({ ...packet, type: "agent-reply" });
          emit({ type: "status", status: { ...status, pushMessage: "Reply reached agent; not acknowledged" } });
          if (packet.requestID === "fixed") {
            sendAgent({ ...packet, type: "resolved", answers: { choice: ["A different terminal answer"] } });
          }
        } else if (packet.type === "control") {
          record({ ...packet, type: "agent-control" });
        }
      }
    });
    emit({ type: "status", status });
  } else if (command.type === "snapshot") {
    requests = command.requests;
    emit({ type: "status", status });
  } else if (command.type === "invite") {
    status.pairingCode = "12345678";
    status.pendingPairingIDs = ["pair"];
    emit({ type: "status", status });
    emit({ type: "pairing", id: "pair", name: "Fixture phone", code: "234567" });
  } else if (command.type === "pair" || command.type === "revoke") {
    record(command);
    status.pendingPairingIDs = [];
    emit({ type: "status", status });
  } else if (command.type === "test-push") {
    step++;
    if (step === 1) {
      const item = requests.find(item => item.request.id === "custom");
      phoneReply("bad-ticket", "custom", "wrong", "My own answer");
      phoneReply("custom-reply", "custom", item.ticket, "My own answer");
    } else if (step === 2) {
      sendAgent({ ...lastReply, type: "resolved" });
    } else if (step === 3) {
      const item = requests.find(item => item.request.id === "fixed");
      phoneReply("fixed-reply", "fixed", item.ticket, "Unsupported custom answer");
    } else if (step === 4) {
      const item = requests.find(item => item.request.id === "fixed");
      phoneReply("mismatched-answer", "fixed", item.ticket, "Listed answer");
    } else if (step === 5) {
      for (let i = 0; i < 16; i++) emit({ type: "workspace_watch", sessionIDs: ["mobile-fixture"] });
    }
  } else {
    record(command);
  }
}
agent?.destroy();
