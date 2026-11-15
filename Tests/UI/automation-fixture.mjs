import { createConnection } from "node:net";
import { appendFileSync, readFileSync } from "node:fs";
import { join } from "node:path";

const directory = process.argv[2];
const sessionID = process.argv[3] ?? "automation-fixture";
const logPrefix = process.argv[3] ? `${sessionID}-` : "";
const connection = JSON.parse(readFileSync(join(directory, "connection.json"), "utf8"));
const agent = createConnection({ host: "127.0.0.1", port: connection.port });
const send = value => agent.write(JSON.stringify({ ...value, sessionID }) + "\n");
agent.on("connect", () => send({ type: "hello", token: connection.token, agent: "copilot", cwd: "/fixture" }));
let buffer = "";
agent.on("data", data => {
  buffer += data;
  let end;
  while ((end = buffer.indexOf("\n")) !== -1) {
    const packet = JSON.parse(buffer.slice(0, end));
    buffer = buffer.slice(end + 1);
    if (packet.type === "welcome") {
      send({ type: "capabilities", sessionAutoYes: true, steering: true, subagentChat: true, subagentStop: true,
        subagentCreate: true, subagentRemove: true, idleSubagentCleanup: true, subagentTypes: ["general-purpose"], subagentModels: ["fixture-model"] });
      send({ type: "team", team: { agents: [{ id: "worker", name: "Fixture helper", task: "Synthetic task", status: "idle" }],
        runningCount: 0, idleCount: 1, truncated: false } });
      if (process.argv[3]) continue;
      for (const id of ["waiting-one", "waiting-two", "restricted"]) {
        send({ type: "request", request: { id, kind: "permission", title: "Synthetic tool request",
          detail: "No command is executed by this fixture.", autoEligible: false,
          sessionAutoEligible: id !== "restricted", questions: [] } });
      }
      send({ type: "request", request: { id: "manual-question", kind: "question", title: "Choose",
        detail: "", autoEligible: false, questions: [{ id: "choice", text: "Choice",
          allowFreeform: true, multiple: false, options: [] }] } });
    } else if (packet.type === "reply") {
      appendFileSync(join(directory, "replies.jsonl"), JSON.stringify(packet) + "\n", { mode: 0o600 });
      send({ ...packet, type: "resolved" });
    } else if (packet.type === "control") {
      appendFileSync(join(directory, `${logPrefix}controls.jsonl`), JSON.stringify(packet) + "\n", { mode: 0o600 });
      send({ type: "control_status", commandID: packet.commandID,
        status: packet.action === "stop_idle_subagents" ? "cleaned" : packet.action === "create_subagent" ? "created" : packet.action === "remove_subagent" ? "removed" :
          packet.action === "stop" ? "stopped" : "received",
        text: "Synthetic delivery acknowledged" });
      if (["create_subagent", "remove_subagent"].includes(packet.action)) {
        send({ type: "team", team: { agents: [
          { id: "worker", name: "Fixture helper", task: "Synthetic task", status: "idle" },
          ...(packet.action === "create_subagent" ? [
            { id: "created-helper", name: packet.agentName, task: packet.text, status: "completed", parentKnown: true }
          ] : [])
        ], runningCount: 0, idleCount: 1, truncated: false } });
      }
    }
  }
});
