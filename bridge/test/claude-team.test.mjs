import { describe, it } from "node:test";
import assert from "node:assert/strict";

// Minimal bridge stub
function makeBridge() {
  const snapshots = [];
  return {
    team(snapshot) { snapshots.push(structuredClone(snapshot)); },
    snapshots,
    latest() { return snapshots.at(-1); }
  };
}

// Import ClaudeTeam from built dist (integration test)
const { ClaudeTeam } = await import("../dist/claude-team.js");

describe("ClaudeTeam", () => {
  it("publishes running agents on start", () => {
    const bridge = makeBridge();
    const team = new ClaudeTeam(bridge);
    team.started({ agent_id: "a1", agent_type: "Explore", prompt: "private instructions" });
    const snap = bridge.latest();
    assert.equal(snap.agents.length, 1);
    assert.equal(snap.agents[0].status, "running");
    assert.equal(snap.runningCount, 1);
    assert.equal(snap.agents[0].task, "");
    assert.equal(snap.agents[0].parentKnown, false);
    team.stop();
  });

  it("uses SDK task identities and real failure status without exposing private prompts", () => {
    const bridge = makeBridge();
    const team = new ClaudeTeam(bridge);
    team.started({ subtype: "task_started", task_id: "b1", task_type: "local_agent", description: "Lint", prompt: "private" });
    team.started({ subtype: "task_started", task_id: "shell", task_type: "local_bash", description: "Not an agent" });
    team.stopped({ subtype: "task_notification", task_id: "b1", status: "failed", summary: "private", output_file: "/secret" });
    const snap = bridge.latest();
    assert.equal(snap.agents.length, 1);
    assert.equal(snap.agents[0].status, "failed");
    assert.equal(snap.agents[0].task, "Lint");
    assert.equal(JSON.stringify(snap).includes("private"), false);
    team.stop();
  });

  it("does not retain non-notify-stopped helpers", () => {
    const bridge = makeBridge();
    const team = new ClaudeTeam(bridge);
    team.started({ agent_id: "c1", agent_type: "Build" });
    team.stopped({ agent_id: "c1" });
    const snap = bridge.latest();
    // completed helper should appear immediately as completed (not cancelled)
    assert.equal(snap.agents.length, 1);
    assert.equal(snap.agents[0].status, "completed");
    team.stop();
  });

  it("bounds observed teams and keeps ended rows stable across unrelated updates", () => {
    const bridge = makeBridge();
    const team = new ClaudeTeam(bridge);
    team.started({ agent_id: "done", agent_type: "Explore" });
    team.stopped({ agent_id: "done" });
    team.started({ agent_id: "next", agent_type: "Explore" });
    assert.equal(bridge.latest().agents.find(a => a.id === "done").status, "completed");
    for (let i = 0; i < 110; i++) team.started({ agent_id: String(i), agent_type: "Explore" });
    assert.equal(bridge.latest().agents.length, 100);
    assert.equal(bridge.latest().truncated, true);
    team.stop();
    const count = bridge.snapshots.length;
    team.started({ agent_id: "late", agent_type: "Explore" });
    assert.equal(bridge.snapshots.length, count);
  });
});
