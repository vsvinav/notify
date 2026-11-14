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
  const agent = new ClaudeAgent(bridge, "unused", undefined, undefined, args =>
    query({ ...args, options: { ...args.options, spawnClaudeCodeProcess: () => child } }));
  const sending = agent.send("test").catch(error => error);
  for (let attempt = 0; attempt < 100 && !bridge.pending.requests.length; attempt++) {
    await new Promise(resolve => setTimeout(resolve, 5));
  }
  assert.equal(bridge.pending.requests.length, 1);
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
