import type { Bridge } from "./connection.ts";
import type { SubagentTeam } from "./subagents.ts";

export class ClaudeTeam {
  private agents = new Map<string, SubagentTeam["agents"][number]>();
  private isStopped = false;
  private truncated = false;

  constructor(private bridge: Pick<Bridge, "team">) {}

  started(event: Record<string, unknown>): void {
    if (this.isStopped) return;
    const sdk = event.subtype === "task_started";
    if (sdk && event.task_type !== "local_agent") return;
    const id = sdk ? event.task_id : event.agent_id;
    if (typeof id !== "string" || !id || id.length > 128) return;
    this.agents.set(id, {
      id, name: String(sdk ? "Agent" : event.agent_type ?? "Agent").slice(0, 160),
      task: sdk && typeof event.description === "string" ? event.description.slice(0, 1000) : "",
      status: "running", parentKnown: false
    });
    if (this.agents.size > 1000) {
      const ended = [...this.agents.values()].find(agent => agent.status !== "running");
      this.agents.delete(ended?.id ?? this.agents.keys().next().value!);
      this.truncated = true;
    }
    this.publish();
  }

  stopped(event: Record<string, unknown>): void {
    if (this.isStopped) return;
    const id = event.subtype === "task_notification" ? event.task_id : event.agent_id;
    if (typeof id !== "string") return;
    const agent = this.agents.get(id);
    if (!agent) return;
    agent.status = event.status === "failed" ? "failed" : event.status === "stopped" ? "cancelled" : "completed";
    this.publish();
  }

  private publish(): void {
    const all = [...this.agents.values()];
    all.sort((a, b) => Number(b.status === "running") - Number(a.status === "running"));
    this.bridge.team({
      agents: all.slice(0, 100), runningCount: all.filter(agent => agent.status === "running").length,
      idleCount: 0, truncated: this.truncated || all.length > 100,
      error: "Only observed Claude subagent lifecycle events are available; idle status and ancestry are unavailable."
    });
  }

  stop(): void {
    this.isStopped = true;
    this.agents.clear();
  }
}
