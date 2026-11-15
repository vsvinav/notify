import type { Bridge } from "./connection.ts";

const KILLED_TTL = 300_000; // 5 minutes

interface Agent {
  id: string;
  name: string;
  task: string;
  status: "running" | "idle" | "completed" | "failed" | "cancelled";
  model?: string;
  parentAgentID?: string;
  parentKnown: boolean;
}

interface CancelledEntry {
  agent: Agent;
  expiresAt: number;
}

export class ClaudeTeam {
  private agents = new Map<string, Agent>();
  private cancelled = new Map<string, CancelledEntry>();
  private notifyStopped = new Set<string>();
  private terminalAgents: Agent[] = [];
  private expiryTimer: NodeJS.Timeout | undefined;
  private isStopped = false;

  constructor(private bridge: Pick<Bridge, "team">) {}

  notifyCancelled(id: string): void {
    this.notifyStopped.add(id);
  }

  started(event: Record<string, unknown>): void {
    const id = String(event.subagent_id ?? event.agentId ?? "");
    const name = String(event.subagent_name ?? event.name ?? "Agent");
    const task = String(event.task ?? event.prompt ?? "");
    const model = typeof event.model === "string" ? event.model : undefined;
    const parentAgentID = typeof event.parent_agent_id === "string" ? event.parent_agent_id : undefined;
    if (!id || id.length > 128) return;
    this.cancelled.delete(id);
    this.agents.set(id, {
      id, name: name.slice(0, 160), task: task.slice(0, 1000),
      status: "running", model: model?.slice(0, 200),
      parentAgentID, parentKnown: parentAgentID !== undefined
    });
    this.publish();
  }

  stopped(event: Record<string, unknown>): void {
    const id = String(event.subagent_id ?? event.agentId ?? "");
    if (!id || id.length > 128) return;
    const agent = this.agents.get(id);
    if (!agent) return;
    const wasNotifyCancelled = this.notifyStopped.has(id);
    if (wasNotifyCancelled) {
      this.notifyStopped.delete(id);
      const updated: Agent = { ...agent, status: "cancelled" };
      this.cancelled.set(id, { agent: updated, expiresAt: Date.now() + KILLED_TTL });
      this.agents.delete(id);
    } else {
      const exitCode = typeof event.exit_code === "number" ? event.exit_code : 0;
      const updated: Agent = { ...agent, status: exitCode === 0 ? "completed" : "failed" };
      this.agents.delete(id);
      this.terminalAgents.push(updated);
    }
    this.publish();
  }

  publish(): void {
    if (this.isStopped) return;
    clearTimeout(this.expiryTimer);
    const now = Date.now();
    // Expire old cancelled entries.
    for (const [id, entry] of this.cancelled) {
      if (entry.expiresAt <= now) this.cancelled.delete(id);
    }
    const live = [...this.agents.values()];
    const retained = [...this.cancelled.values()].map(e => e.agent);
    const terminal = this.terminalAgents.splice(0);
    const all = [...live, ...retained, ...terminal];
    const running = all.filter(a => a.status === "running");
    const idle = all.filter(a => a.status === "idle");
    this.bridge.team({
      agents: all.slice(0, 100).map(a => ({
        id: a.id, name: a.name, task: a.task, status: a.status,
        ...(a.model ? { model: a.model } : {}),
        parentKnown: a.parentKnown,
        ...(a.parentAgentID ? { parentAgentID: a.parentAgentID } : {})
      })),
      runningCount: running.length,
      idleCount: idle.length,
      truncated: all.length > 100,
    });
    // Schedule re-publish when next TTL expires.
    let nextExpiry = Infinity;
    for (const entry of this.cancelled.values()) {
      nextExpiry = Math.min(nextExpiry, entry.expiresAt);
    }
    if (Number.isFinite(nextExpiry)) {
      this.expiryTimer = setTimeout(() => this.publish(), Math.max(1, nextExpiry - Date.now()));
    }
  }

  stop(): void {
    this.isStopped = true;
    clearTimeout(this.expiryTimer);
    this.agents.clear();
    this.cancelled.clear();
    this.notifyStopped.clear();
    this.terminalAgents = [];
  }
}
