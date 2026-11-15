import type { CopilotSession } from "@github/copilot-sdk";
import type { Bridge } from "./connection.ts";
import type { attachSubagents } from "./subagents.ts";
import { object } from "./protocol.ts";

type Receipt = { action: string; status: string; text: string; message: string; agentID?: string; agentName?: string; agentType?: string; model?: string };
const boundedText = (value: unknown, limit: number): value is string =>
  typeof value === "string" && !!value.trim() && value.length <= limit;
const management = (action: unknown) => action === "create_subagent" || action === "remove_subagent" || action === "stop_idle_subagents";

export function attachSteering(session: CopilotSession, bridge: Bridge,
  team?: Pick<ReturnType<typeof attachSubagents>, "refresh" | "removed" | "isRetainedCancelled" | "cancelled"> &
    Partial<Pick<ReturnType<typeof attachSubagents>, "stopIdleSubagents" | "cleanupAvailable" | "onCleanupAvailability">>) {
  const receipts = new Map<string, Receipt>();
  let stopped = false;
  let busy = false;
  function status(id: string, value: string, text: string) {
    const receipt = receipts.get(id);
    if (!receipt) return;
    receipt.status = value; receipt.text = text;
    bridge.controlStatus(id, value, text);
  }
  const subagentChat = typeof session.rpc.tasks?.sendMessage === "function";
  const subagentStop = typeof session.rpc.tasks?.cancel === "function";
  const canCreate = typeof session.rpc.agent?.list === "function" && typeof session.rpc.tasks?.startAgent === "function" &&
    typeof session.rpc.tasks?.list === "function";
  const subagentRemove = typeof session.rpc.tasks?.remove === "function" && typeof session.rpc.tasks?.list === "function";
  let subagentTypes: string[] = [];
  let subagentModels: string[] = [];
  let agentNames = new Map<string, string>();
  function capabilities() {
    if (!stopped) bridge.setCapabilities({ steering: true, sessionAutoYes: true, subagentChat, subagentStop,
      subagentCreate: canCreate && subagentTypes.length > 0, subagentRemove, subagentTypes, subagentModels,
      idleSubagentCleanup: subagentStop && typeof session.rpc.tasks?.list === "function" &&
        typeof team?.stopIdleSubagents === "function" && team.cleanupAvailable === true });
  }
  const unsubscribeCleanup = team?.onCleanupAvailability?.(capabilities);
  async function modelCatalog(): Promise<string | undefined> {
    try {
      if (typeof session.rpc.model?.list !== "function") throw new Error("This runtime does not support session model listing.");
      const result = await session.rpc.model.list({ skipCache: true });
      if (!Array.isArray(result.list) || result.list.length > 200 ||
          result.list.some(model => !object(model) || !boundedText(model.id, 200)) ||
          new Set(result.list.map(model => (model as { id: string }).id)).size !== result.list.length) {
        throw new Error("The runtime supplied an invalid session model catalog.");
      }
      subagentModels = result.list.flatMap(model => object(model) &&
        (model.policy === undefined || (object(model.policy) && model.policy.state === "enabled")) ? [model.id as string] : []);
      capabilities();
    } catch (error) {
      subagentModels = [];
      capabilities();
      const text = `Subagent model catalog unavailable; configured default remains available: ${String(error)}`;
      if (!stopped) bridge.error(text);
      return text;
    }
  }
  async function catalog(): Promise<string | undefined> {
    if (!canCreate) return "This runtime does not support subagent creation and live catalog lookup.";
    try {
      const result = await session.rpc.agent.list({ includeBuiltInAgents: true });
      if (!Array.isArray(result.agents) || result.agents.length > 100 ||
          result.agents.some(agent => !object(agent) || !boundedText(agent.id, 128) || !boundedText(agent.name, 128)) ||
          new Set(result.agents.map(agent => agent.id)).size !== result.agents.length ||
          new Set(result.agents.map(agent => agent.name)).size !== result.agents.length) {
        throw new Error("The runtime supplied an invalid subagent type catalog.");
      }
      subagentTypes = result.agents.map(agent => agent.id);
      agentNames = new Map(result.agents.map(agent => [agent.id, agent.name]));
      capabilities();
    } catch (error) {
      subagentTypes = [];
      agentNames.clear();
      capabilities();
      const text = `Subagent type catalog unavailable: ${String(error)}`;
      if (!stopped) bridge.error(text);
      return text;
    }
  }
  capabilities();
  const ready = catalog();
  const modelsReady = canCreate ? modelCatalog() : Promise.resolve();
  bridge.onControl = async value => {
    if (stopped || !object(value) || typeof value.commandID !== "string" ||
        !/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(value.commandID) ||
        !["queue", "interrupt", "stop", "create_subagent", "remove_subagent", "stop_idle_subagents"].includes(String(value.action)) ||
        typeof value.text !== "string" || value.text.length > 16000 ||
        (!["stop", "remove_subagent", "stop_idle_subagents"].includes(String(value.action)) && !value.text.trim()) ||
        (value.action === "create_subagent"
          ? (!boundedText(value.agentName, 160) || !boundedText(value.agentType, 128) || value.agentID !== undefined)
          : (value.agentName !== undefined || value.agentType !== undefined)) ||
        (value.model !== undefined && (value.action !== "create_subagent" || !boundedText(value.model, 200))) ||
        (value.action === "remove_subagent" && (value.text !== "" || !boundedText(value.agentID, 128))) ||
        (value.action === "stop_idle_subagents" && (value.text !== "" || value.agentID !== undefined)) ||
        (value.agentID !== undefined && (typeof value.agentID !== "string" || !value.agentID || value.agentID.length > 128 ||
          value.action === "interrupt"))) throw new Error("Invalid or unavailable steering command.");
    const agentID = typeof value.agentID === "string" ? value.agentID : undefined;
    const agentName = typeof value.agentName === "string" ? value.agentName : undefined;
    const agentType = typeof value.agentType === "string" ? value.agentType : undefined;
    const model = typeof value.model === "string" ? value.model : undefined;
    const id = value.commandID;
    const previous = receipts.get(id);
    if (previous) {
      if (previous.action !== value.action || previous.message !== value.text || previous.agentID !== agentID ||
          previous.agentName !== agentName || previous.agentType !== agentType || previous.model !== model) {
        throw new Error("A repeated command changed its target or content.");
      }
      bridge.controlStatus(id, previous.status, previous.text); return;
    }
    if (busy) throw new Error("A steering command is still being delivered. Wait before sending another.");
    if (receipts.size >= 1000) throw new Error("Steering history is full. Reload the Notify extension before sending more.");
    receipts.set(id, { action: String(value.action), status: "sending", text: "Delivering to Copilot...", message: value.text, agentID, agentName, agentType, model });
    busy = true;
    let interrupted = false;
    let dispatched = false;
    try {
      if (value.action === "stop_idle_subagents") {
        if (!subagentStop || typeof session.rpc.tasks?.list !== "function" || !team?.stopIdleSubagents) {
          status(id, "failed", "Cancelled 0; skipped 0; failed 0; uncertain 0. This runtime does not support observed idle subagent cleanup.");
          return;
        }
        const result = await team.stopIdleSubagents(() => stopped);
        status(id, result.status, result.text);
        if (!stopped) await team.refresh();
      } else if (value.action === "create_subagent") {
        await ready;
        if (model !== undefined) {
          await modelsReady;
          const error = await modelCatalog();
          if (error || !subagentModels.includes(model)) {
            status(id, "failed", error || "This model is no longer available for selection in the live session catalog."); return;
          }
        }
        const error = await catalog();
        if (error || !subagentTypes.includes(agentType!)) {
          status(id, "failed", error || "This subagent type is no longer available in the live catalog."); return;
        }
        if (stopped) { status(id, "failed", "Extension detached before dispatch."); return; }
        dispatched = true;
        // Runtime 1.0.112 starts by invocation name, not the catalog's stable selection ID.
        const result = await session.rpc.tasks.startAgent({ agentType: agentNames.get(agentType!)!, prompt: value.text, name: agentName!,
          ...(model !== undefined ? { model } : {}) });
        if (!boundedText(result.agentId, 128)) throw new Error("The runtime did not return a valid created agent identity.");
        status(id, "created", `Created subagent “${agentName}”. ${model === undefined ? "Runtime model defaults apply." : `Requested model: ${model}.`}`);
        await team?.refresh();
      } else if (value.action === "remove_subagent") {
        if (!subagentRemove) { status(id, "failed", "This runtime does not support subagent removal."); return; }
        const task = (await session.rpc.tasks.list()).tasks.find(task => task.id === agentID && task.type === "agent");
        if (!task || !["completed", "failed", "cancelled"].includes(task.status)) {
          status(id, "failed", !task && team?.isRetainedCancelled(agentID!)
            ? "This retained cancelled helper is already absent from the runtime. No runtime removal was performed."
            : "Only a known ended subagent can be removed. Nothing was stopped or removed.");
          return;
        }
        if (stopped) { status(id, "failed", "Extension detached before dispatch."); return; }
        dispatched = true;
        const result = await session.rpc.tasks.remove({ id: agentID! });
        if (result.removed !== true) { status(id, "failed", "The runtime did not remove this subagent. Nothing was stopped."); return; }
        team?.removed(agentID!);
        status(id, "removed", "Ended subagent removed from the list. No files were deleted; other agents were not changed.");
        await team?.refresh();
      } else if (agentID) {
        if (value.action === "stop" ? !subagentStop : !subagentChat) {
          status(id, "failed", "This runtime does not support the requested subagent control."); return;
        }
        const task = (await session.rpc.tasks.list()).tasks.find(task => task.id === agentID && task.type === "agent");
        if (!task || !["running", "idle"].includes(task.status)) {
          status(id, "failed", "This subagent is no longer active. Nothing was sent."); return;
        }
        if (stopped) { status(id, "failed", "Extension detached before dispatch."); return; }
        if (value.action === "stop") {
          const result = await session.rpc.tasks.cancel({ id: agentID });
          if (result.cancelled) team?.cancelled(agentID!);
          status(id, result.cancelled ? "stopped" : "failed", result.cancelled
            ? "Subagent stop acknowledged. Other agents were not stopped." : "The runtime did not cancel this subagent.");
        } else {
          const result = await session.rpc.tasks.sendMessage({ id: agentID, message: value.text });
          status(id, result.sent ? "received" : "failed", result.sent ? "Delivered to this subagent." :
            result.error || "The runtime rejected this subagent message.");
        }
      } else if (value.action === "stop") {
        await session.abort();
        for (const [queuedID, receipt] of receipts) {
          if (queuedID !== id && !receipt.agentID && receipt.status === "queued") status(queuedID, "cancelled", "Queue cleared by Stop.");
        }
        status(id, "stopped", "Stop acknowledged. Queued prompts were cleared; existing changes were not undone.");
      } else {
        if (value.action === "interrupt") {
          interrupted = (await session.rpc.interruptMainTurn({ flushQueued: true })).interrupted;
          if (stopped) throw new Error("Extension detached before the message was sent.");
        }
        await session.send({ prompt: value.text, mode: value.action === "queue" ? "enqueue" : "immediate", clientTurnId: id });
        if (receipts.get(id)?.status !== "received") {
          status(id, "queued", value.action === "queue"
            ? "Accepted into Copilot's queue. Waiting for it to consume the message."
            : "Direction submitted. Waiting for Copilot to consume it.");
        }
      }
    } catch (error) {
      if (!["received", "created", "removed", "cleaned"].includes(receipts.get(id)?.status ?? "")) {
        status(id, management(value.action) && !dispatched ? "failed" : "unknown",
          `${interrupted ? "Main turn interrupted. " : ""}${management(value.action) && !dispatched
            ? "Nothing was dispatched." : "Delivery is uncertain; check the session before resending."} ${String(error)}`);
      }
    } finally { busy = false; }
  };
  const unsubscribe = session.on(event => {
    if (event.type === "session.custom_agents_updated") { void catalog(); return; }
    if (event.type === "session.model_change" && canCreate) { void modelCatalog(); return; }
    if (event.type === "user.message" && !event.agentId && event.data.clientTurnId &&
        receipts.has(event.data.clientTurnId) && !receipts.get(event.data.clientTurnId)?.agentID &&
        !management(receipts.get(event.data.clientTurnId)?.action)) {
      status(event.data.clientTurnId, "received", "Received by Copilot. Agent activity is shown separately below.");
    }
  });
  return {
    ready: Promise.all([ready, modelsReady]),
    stop() {
      stopped = true;
      unsubscribe();
      unsubscribeCleanup?.();
      bridge.onControl = undefined;
      bridge.setCapabilities({ steering: false, sessionAutoYes: false, subagentChat: false, subagentStop: false,
        subagentCreate: false, subagentRemove: false, subagentTypes: [], subagentModels: [], idleSubagentCleanup: false });
    }
  };
}
