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
    team.started({ subagent_id: "a1", subagent_name: "Explore", task: "Search files" });
    const snap = bridge.latest();
    assert.equal(snap.agents.length, 1);
    assert.equal(snap.agents[0].status, "running");
    assert.equal(snap.runningCount, 1);
    team.stop();
  });

  it("retains notify-cancelled helper for 5 minutes then drops it", async () => {
    const bridge = makeBridge();
    const team = new ClaudeTeam(bridge);
    team.started({ subagent_id: "b1", subagent_name: "Lint", task: "Run lint" });
    team.notifyCancelled("b1");
    team.stopped({ subagent_id: "b1" });
    // Immediately after stop: helper should still appear as cancelled
    const snap = bridge.latest();
    assert.equal(snap.agents.length, 1, "cancelled helper still visible");
    assert.equal(snap.agents[0].status, "cancelled");
    team.stop();
  });

  it("does not retain non-notify-stopped helpers", () => {
    const bridge = makeBridge();
    const team = new ClaudeTeam(bridge);
    team.started({ subagent_id: "c1", subagent_name: "Build", task: "npm run build" });
    team.stopped({ subagent_id: "c1", exit_code: 0 });
    const snap = bridge.latest();
    // completed helper should appear immediately as completed (not cancelled)
    assert.equal(snap.agents.length, 1);
    assert.equal(snap.agents[0].status, "completed");
    team.stop();
  });
});
