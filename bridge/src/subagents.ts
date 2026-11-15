import type { CopilotSession } from "@github/copilot-sdk";
import type { Bridge } from "./connection.ts";

export interface SubagentTeam {
  agents: { id: string; name: string; task: string; status: "running" | "idle" | "completed" | "failed" | "cancelled"; model?: string; parentKnown: boolean; parentAgentID?: string }[];
  runningCount: number;
  idleCount: number;
  truncated: boolean;
  error?: string;
}

export function attachSubagents(session: CopilotSession, bridge: Pick<Bridge, "team">) {
  let stopped = false, requested = false;
  let pending: Promise<void> | undefined;
  let timer: NodeJS.Timeout | undefined, watchdog: NodeJS.Timeout | undefined;
  let expiryTimer: NodeJS.Timeout | undefined;
  let latest: SubagentTeam | undefined;
  const parents = new Map<string, string | null>();
  const cancelled = new Map<string, { expiresAt: number; agent?: SubagentTeam["agents"][number] }>();
  const removed = new Set<string>();
  const rank = (status: string) => status === "running" ? 0 : status === "idle" ? 1 : status === "cancelled" ? 2 : 3;
  function publish() {
    clearTimeout(expiryTimer);
    if (stopped || !latest) return;
    const retained: SubagentTeam["agents"] = [];
    let nextExpiry = Infinity;
    for (const item of cancelled.values()) {
      if (item.expiresAt <= Date.now()) { item.agent = undefined; continue; }
      if (item.agent) retained.push(item.agent);
      nextExpiry = Math.min(nextExpiry, item.expiresAt);
    }
    const agents = [...latest.agents, ...retained].sort((a, b) => rank(a.status) - rank(b.status));
    bridge.team({ ...latest, agents: agents.slice(0, 100), truncated: latest.truncated || agents.length > 100 });
    if (Number.isFinite(nextExpiry)) expiryTimer = setTimeout(publish, Math.max(1, nextExpiry - Date.now()));
  }
  function unavailable(error: unknown) {
    if (stopped) return;
    latest = undefined;
    clearTimeout(expiryTimer);
    const text = `Subagent status unavailable: ${error instanceof Error ? error.message : String(error)}`.slice(0, 1000);
    console.error(`Notify: ${text}`);
    bridge.team({ agents: [], runningCount: 0, idleCount: 0, truncated: false, error: text });
  }
  function refresh(): Promise<void> {
    if (stopped) return Promise.resolve();
    requested = true;
    if (pending) return pending;
    pending = (async () => {
      while (requested && !stopped) {
        requested = false;
        watchdog = setTimeout(() => unavailable(new Error("The runtime did not respond.")), 5000);
        try {
          const { tasks } = await session.rpc.tasks.list();
          if (stopped) break;
          const agents = tasks.filter(task => task.type === "agent").filter(task => !removed.has(task.id));
          const runningCount = agents.filter(task => task.status === "running").length;
          const idleCount = agents.filter(task => task.status === "idle").length;
          agents.sort((a, b) => {
            return rank(a.status) - rank(b.status) || b.startedAt.localeCompare(a.startedAt) || a.id.localeCompare(b.id);
          });
          const seen = new Set(agents.map(task => task.id));
          for (const [id, item] of cancelled) {
            if (!seen.has(id) && item.expiresAt <= Date.now()) cancelled.delete(id);
          }
          const rows: SubagentTeam["agents"] = [];
          for (const task of agents) {
              if (!task.id || task.id.length > 128) throw new Error("The runtime supplied an invalid subagent identity.");
              const parentAgentID = parents.get(task.toolCallId) ?? undefined;
              const row = {
                id: task.id, name: (task.displayName || task.agentType).slice(0, 160),
                task: task.description.slice(0, 1000), status: task.status,
                model: (task.resolvedModel || task.model)?.slice(0, 200),
                parentKnown: parents.has(task.toolCallId), ...(parentAgentID ? { parentAgentID } : {})
              };
              if (task.status === "cancelled") {
                const completedAt = task.completedAt ? Date.parse(task.completedAt) : NaN;
                const expiresAt = cancelled.get(task.id)?.expiresAt ??
                  Math.min(Date.now(), Number.isFinite(completedAt) ? completedAt : Date.now()) + 300000;
                cancelled.set(task.id, { expiresAt, ...(expiresAt > Date.now() ? { agent: row } : {}) });
              } else {
                cancelled.delete(task.id);
                rows.push(row);
              }
          }
          latest = { agents: rows.slice(0, 100), runningCount, idleCount, truncated: rows.length > 100 };
          publish();
        } catch (error) { unavailable(error); }
        finally { clearTimeout(watchdog); watchdog = undefined; }
      }
    })().finally(() => { pending = undefined; });
    return pending;
  }
  const unsubscribe = session.on(event => {
    if (stopped) return;
    if (event.type === "subagent.started") {
      const { toolCallId, parentId } = event.data;
      if (!toolCallId || toolCallId.length > 128 || (parentId !== undefined && (!parentId || parentId.length > 128))) {
        unavailable(new Error("The runtime supplied invalid subagent ancestry."));
        return;
      }
      parents.set(toolCallId, parentId ?? null);
      // Old, unobserved ancestry remains explicitly unknown instead of retaining an entire transcript.
      if (parents.size > 1000) parents.delete(parents.keys().next().value!);
    } else if (event.type !== "session.background_tasks_changed") return;
    if (timer) return;
    timer = setTimeout(() => { timer = undefined; void refresh(); }, 100);
  });
  return {
    refresh,
    isRetainedCancelled(id: string) {
      const item = cancelled.get(id);
      return !!item?.agent && item.expiresAt > Date.now();
    },
    removed(id: string) {
      removed.add(id);
      cancelled.delete(id);
      if (latest) {
        const row = latest.agents.find(agent => agent.id === id);
        latest = { ...latest, agents: latest.agents.filter(agent => agent.id !== id),
          runningCount: latest.runningCount - Number(row?.status === "running"),
          idleCount: latest.idleCount - Number(row?.status === "idle") };
      }
      publish();
    },
    stop() {
      stopped = true; clearTimeout(timer); clearTimeout(watchdog); clearTimeout(expiryTimer);
      unsubscribe(); parents.clear(); cancelled.clear(); removed.clear(); latest = undefined;
    }
  };
}
