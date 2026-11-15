import type { CopilotSession } from "@github/copilot-sdk";
import type { Bridge } from "./connection.ts";

export interface SubagentTeam {
  agents: { id: string; name: string; task: string; status: "running" | "idle" | "completed" | "failed" | "cancelled"; model?: string }[];
  runningCount: number;
  idleCount: number;
  truncated: boolean;
  error?: string;
}

export function attachSubagents(session: CopilotSession, bridge: Pick<Bridge, "team">) {
  let stopped = false, requested = false;
  let pending: Promise<void> | undefined;
  let timer: NodeJS.Timeout | undefined, watchdog: NodeJS.Timeout | undefined;
  function unavailable(error: unknown) {
    if (stopped) return;
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
          const agents = tasks.filter(task => task.type === "agent");
          const runningCount = agents.filter(task => task.status === "running").length;
          const idleCount = agents.filter(task => task.status === "idle").length;
          agents.sort((a, b) => {
            const rank = (status: string) => status === "running" ? 0 : status === "idle" ? 1 : 2;
            return rank(a.status) - rank(b.status) || b.startedAt.localeCompare(a.startedAt) || a.id.localeCompare(b.id);
          });
          bridge.team({
            agents: agents.slice(0, 100).map(task => {
              if (!task.id || task.id.length > 128) throw new Error("The runtime supplied an invalid subagent identity.");
              return {
                id: task.id, name: (task.displayName || task.agentType).slice(0, 160),
                task: task.description.slice(0, 1000), status: task.status,
                model: (task.resolvedModel || task.model)?.slice(0, 200)
              };
            }),
            runningCount, idleCount, truncated: agents.length > 100
          });
        } catch (error) { unavailable(error); }
        finally { clearTimeout(watchdog); watchdog = undefined; }
      }
    })().finally(() => { pending = undefined; });
    return pending;
  }
  const unsubscribe = session.on(event => {
    if (event.type !== "session.background_tasks_changed" || timer || stopped) return;
    timer = setTimeout(() => { timer = undefined; void refresh(); }, 100);
  });
  return {
    refresh,
    stop() { stopped = true; clearTimeout(timer); clearTimeout(watchdog); unsubscribe(); }
  };
}
