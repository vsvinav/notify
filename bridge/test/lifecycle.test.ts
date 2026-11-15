import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { PassThrough, Writable } from "node:stream";
import { query } from "@anthropic-ai/claude-agent-sdk";
import { Bridge } from "../dist/connection.js";
import { ClaudeAgent } from "../dist/agents.js";

test("failed Claude process invalidates pending approvals without a late SDK write", async () => {
  class FakeProcess extends EventEmitter {
    stdout = new PassThrough();
    killed = false;
    exitCode: number | null = null;
    kill() { this.killed = true; return true; }
    stdin = new Writable({
      write: (data, _encoding, callback) => {
        for (const line of data.toString().trim().split("\n")) {
          const packet = JSON.parse(line);
          if (packet.type === "control_request" && packet.request.subtype === "initialize") {
            queueMicrotask(() => {
              this.stdout.write(JSON.stringify({ type: "control_response", response: {
                subtype: "success", request_id: packet.request_id, response: {}
              } }) + "\n");
              for (const [id, parent, text] of [
                ["main-reply", null, "## Result\n\n```swift\nlet ready = true\n```"],
                ["child-reply", "child-tool", "Child response"]
              ]) {
                this.stdout.write(JSON.stringify({
                  type: "assistant", uuid: id, session_id: "fixture", parent_tool_use_id: parent,
                  message: { role: "assistant", content: [{ type: "text", text }] }
                }) + "\n");
              }
              setImmediate(() => this.stdout.write(JSON.stringify({
                type: "control_request", request_id: "sdk-request",
                request: { subtype: "can_use_tool", tool_name: "Bash", input: { command: "example" }, tool_use_id: "tool" }
              }) + "\n"));
            });
          }
        }
        callback();
      }
    });
  }
  const child = new FakeProcess();
  const bridge = new Bridge("claude", process.cwd());
  const activity: { id: string; detail: string; agentID?: string }[] = [];
  bridge.activity = entry => { activity.push(entry); };
  const agent = new ClaudeAgent(bridge, "unused", undefined, undefined, args =>
    query({ ...args, options: { ...args.options, spawnClaudeCodeProcess: () => child } }));
  const sending = agent.send("test").catch(error => error);
  for (let attempt = 0; attempt < 100 && !bridge.pending.requests.length; attempt++) {
    await new Promise(resolve => setTimeout(resolve, 5));
  }
  assert.equal(bridge.pending.requests.length, 1);
  assert.equal(activity.length, 2, "Claude responses must reach the structured response feed");
  assert.equal(activity[0].detail, "## Result\n\n```swift\nlet ready = true\n```");
  assert.equal(activity[0].agentID, undefined);
  assert.equal(activity[1].agentID, "child-tool", "Child responses must not be presented as the main agent");
  const id = bridge.pending.requests[0].id;
  child.exitCode = 1;
  child.stdout.end();
  child.emit("exit", 1, null);
  const error = await sending;
  assert.match(error.message, /exited with code 1/);
  assert.equal(bridge.pending.requests.length, 0);
  assert.equal(bridge.pending.reply({ requestID: id, decision: "allow" }), false);
  await new Promise(resolve => setTimeout(resolve, 30));
  bridge.stop();
});
