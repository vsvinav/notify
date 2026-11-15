import type { CopilotSession } from "@github/copilot-sdk";
import type { Bridge } from "./connection.ts";
import { createHash } from "node:crypto";

export interface SubagentTeam {
  agents: { id: string; name: string; task: string; status: "running" | "idle" | "completed" | "failed" | "cancelled"; model?: string; parentKnown: boolean; parentAgentID?: string }[];
  runningCount: number;
  idleCount: number;
  truncated: boolean;
  error?: string;
}

export function attachSubagents(session: CopilotSession, bridge: Pick<Bridge, "team" | "onConnectionChange">) {
  let stopped = false, requested = false, runtimeEnded = false;
  let pending: Promise<void> | undefined;
  let timer: NodeJS.Timeout | undefined, watchdog: NodeJS.Timeout | undefined;
  let expiryTimer: NodeJS.Timeout | undefined;
  let latest: SubagentTeam | undefined;
  const parents = new Map<string, string | null>();
  const cancelled = new Map<string, { expiresAt: number; agent?: SubagentTeam["agents"][number] }>();
  const removed = new Set<string>();
  type AgentTask = Extract<Awaited<ReturnType<typeof session.rpc.tasks.list>>["tasks"][number], { type: "agent" }>;
  const idle = new Map<string, { signature: string; since: number }>();
  const availabilityListeners = new Set<() => void>();
  let observationVersion = 0, disconnectVersion = 0, readVersion = 0, available = false;
  const supported = typeof session.rpc.tasks?.list === "function" && typeof session.rpc.tasks?.cancel === "function";
  function availability(value: boolean) {
    if (available === value) return;
    available = value;
    for (const listener of availabilityListeners) listener();
  }
  function resetIdleObservation() {
    observationVersion++; disconnectVersion++;
    idle.clear();
    availability(false);
  }
  async function readObservedTasks(): Promise<AgentTask[]> {
    if (runtimeEnded) throw new Error("The runtime session ended.");
    const version = observationVersion, read = ++readVersion;
    const { tasks } = await session.rpc.tasks.list();
    if (stopped || version !== observationVersion || read !== readVersion) {
      throw new Error("Subagent observation changed during the live lookup. Nothing further was dispatched.");
    }
    if (!Array.isArray(tasks)) throw new Error("Invalid runtime task snapshot.");
    const agents = tasks.filter((task): task is AgentTask => task.type === "agent");
    if (agents.length > 1000 || new Set(agents.map(task => task.id)).size !== agents.length ||
        agents.some(task => !task.id || task.id.length > 128 || !task.toolCallId || task.toolCallId.length > 128 ||
          !["idle", "running", "completed", "failed", "cancelled"].includes(task.status))) {
      throw new Error("Subagent snapshot is invalid or exceeds the safe observation limit.");
    }
    const seen = new Set(agents.map(task => task.id));
    for (const id of idle.keys()) if (!seen.has(id)) idle.delete(id);
    for (const task of agents) {
      if (task.status !== "idle" || removed.has(task.id)) { idle.delete(task.id); continue; }
      const signature = createHash("sha256").update(JSON.stringify(task)).digest("hex");
      if (idle.get(task.id)?.signature !== signature) idle.set(task.id, { signature, since: performance.now() });
    }
    availability(supported);
    return agents;
  }
  function eligible(agents: AgentTask[]) {
    const byID = new Map(agents.map(task => [task.id, task]));
    const paths = new Map<string, string[]>();
    let unsafe = false;
    for (const task of agents.filter(task => task.status === "idle" || task.status === "running")) {
      const path: string[] = [];
      const visited = new Set<string>();
      let current: AgentTask | undefined = task;
      while (current) {
        if (visited.has(current.id) || !parents.has(current.toolCallId) || current.id === session.sessionId) {
          unsafe = true; break;
        }
        visited.add(current.id);
        path.push(current.id);
        const parent = parents.get(current.toolCallId);
        if (parent === null) break;
        current = byID.get(parent!);
        if (!current) unsafe = true;
      }
      paths.set(task.id, path);
    }
    // An unplaced active task could be a descendant of any candidate.
    if (unsafe) return [];
    const oldIdle = (id: string) => {
      const observation = idle.get(id);
      return byID.get(id)?.status === "idle" && !removed.has(id) && observation !== undefined &&
        performance.now() - observation.since > 600000;
    };
    const protectedIDs = new Set<string>();
    for (const [id, path] of paths) if (!oldIdle(id)) for (const ancestor of path) protectedIDs.add(ancestor);
    return agents.filter(task => oldIdle(task.id) && paths.has(task.id) && !protectedIDs.has(task.id))
      .sort((a, b) => paths.get(b.id)!.length - paths.get(a.id)!.length);
  }
  async function stopIdleSubagents(detached: () => boolean = () => false) {
    const counts = { cancelled: 0, skipped: 0, failed: 0, unknown: 0 };
    let total = 0, failure = "", uncertain = false;
    const connection = disconnectVersion;
    try {
      if (!supported || stopped || detached()) throw new Error("Idle subagent cleanup is unavailable or detached.");
      const agents = await readObservedTasks();
      total = agents.length;
      if (stopped || detached() || disconnectVersion !== connection) throw new Error("Disconnected during cleanup evaluation.");
      const candidates = eligible(agents);
      for (const candidate of candidates) {
        if (stopped || detached() || disconnectVersion !== connection) throw new Error("Disconnected before the next cancellation.");
        const live = await readObservedTasks();
        if (stopped || detached() || disconnectVersion !== connection) throw new Error("Disconnected before the next cancellation.");
        if (!eligible(live).some(task => task.id === candidate.id)) continue;
        // The pinned API has no atomic idle/ancestry predicate; a runtime race remains after this check.
        try {
          const result = await session.rpc.tasks.cancel({ id: candidate.id });
          if (result?.cancelled === false) {
            counts.failed++; failure = "The runtime rejected a cancellation; the remaining batch was not dispatched."; break;
          }
          if (result?.cancelled !== true) throw new Error("The runtime returned no valid cancellation acknowledgement.");
          counts.cancelled++;
          idle.delete(candidate.id);
        } catch (error) {
          counts.unknown++; uncertain = true;
          failure = `Cancellation outcome is uncertain; the remaining batch was not dispatched. ${String(error)}`;
          break;
        }
      }
    } catch (error) {
      idle.clear(); availability(false);
      failure = String(error);
    }
    counts.skipped = Math.max(0, total - counts.cancelled - counts.failed - counts.unknown);
    return { ...counts, status: uncertain ? "unknown" : failure ? "failed" : "cleaned",
      text: `Cancelled ${counts.cancelled}; skipped ${counts.skipped}; failed ${counts.failed}; uncertain ${counts.unknown}. ` +
        (failure || "Batch complete. Skips include unknown/young idle age, active or ended tasks, unsafe ancestry and protected descendants.") +
        " Main agent was not targeted. Live checks cannot eliminate the runtime race before cancellation." };
  }
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
    observationVersion++;
    idle.clear(); availability(false);
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
          const tasks = await readObservedTasks();
          if (stopped) break;
          const agents = tasks.filter(task => !removed.has(task.id));
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
    if (["session.start", "session.resume", "session.shutdown"].includes(event.type)) {
      resetIdleObservation(); parents.clear();
      runtimeEnded = event.type === "session.shutdown";
      return;
    }
    if (event.agentId || event.type.startsWith("subagent.") || event.type === "session.background_tasks_changed" ||
        event.type === "session.error") {
      observationVersion++;
      if (event.agentId && !event.type.startsWith("subagent.") && event.type !== "session.background_tasks_changed") idle.delete(event.agentId);
      else idle.clear();
    }
    if (event.type === "subagent.started") {
      const { toolCallId, parentId } = event.data;
      if (typeof toolCallId !== "string" || !toolCallId || toolCallId.length > 128 ||
          (parentId !== undefined && (typeof parentId !== "string" || !parentId || parentId.length > 128))) {
        parents.clear();
        unavailable(new Error("The runtime supplied invalid subagent ancestry."));
        return;
      }
      parents.set(toolCallId, parentId ?? null);
      // Old, unobserved ancestry remains explicitly unknown instead of retaining an entire transcript.
      if (parents.size > 1000) parents.delete(parents.keys().next().value!);
    } else if (event.type !== "session.background_tasks_changed" &&
        !event.type.startsWith("subagent.") && event.type !== "session.error") return;
    if (timer) return;
    timer = setTimeout(() => { timer = undefined; void refresh(); }, 100);
  });
  const connectionChanged = (connected: boolean) => {
    resetIdleObservation();
    if (connected) void refresh();
  };
  bridge.onConnectionChange = connectionChanged;
  return {
    refresh,
    stopIdleSubagents,
    resetIdleObservation,
    get cleanupAvailable() { return !stopped && available; },
    onCleanupAvailability(listener: () => void) {
      availabilityListeners.add(listener);
      return () => { availabilityListeners.delete(listener); };
    },
    isRetainedCancelled(id: string) {
      const item = cancelled.get(id);
      return !!item?.agent && item.expiresAt > Date.now();
    },
    cancelled(id: string) {
      if (!id || id.length > 128) return;
      const existing = cancelled.get(id);
      if (existing) return; // already tracked with an expiry
      cancelled.set(id, { expiresAt: Date.now() + 300000 });
      // agent row will be filled in on the next refresh pass
    },
    removed(id: string) {
      idle.delete(id);
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
      resetIdleObservation(); availabilityListeners.clear();
      if (bridge.onConnectionChange === connectionChanged) bridge.onConnectionChange = undefined;
      unsubscribe(); parents.clear(); cancelled.clear(); removed.clear(); latest = undefined;
    }
  };
}
