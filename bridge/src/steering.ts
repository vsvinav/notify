import type { CopilotSession } from "@github/copilot-sdk";
import type { Bridge } from "./connection.ts";
import { object } from "./protocol.ts";

type Receipt = { action: string; status: string; text: string; message: string; agentID?: string };

export function attachSteering(session: CopilotSession, bridge: Bridge) {
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
  bridge.setCapabilities({ steering: true, sessionAutoYes: true, subagentChat, subagentStop });
  bridge.onControl = async value => {
    if (stopped || !object(value) || typeof value.commandID !== "string" ||
        !/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(value.commandID) ||
        !["queue", "interrupt", "stop"].includes(String(value.action)) ||
        typeof value.text !== "string" || value.text.length > 16000 ||
        (value.action !== "stop" && !value.text.trim()) ||
        (value.agentID !== undefined && (typeof value.agentID !== "string" || !value.agentID || value.agentID.length > 128 ||
          value.action === "interrupt"))) throw new Error("Invalid or unavailable steering command.");
    const agentID = typeof value.agentID === "string" ? value.agentID : undefined;
    const id = value.commandID;
    const previous = receipts.get(id);
    if (previous) {
      if (previous.action !== value.action || previous.message !== value.text || previous.agentID !== agentID) {
        throw new Error("A repeated command changed its target or content.");
      }
      bridge.controlStatus(id, previous.status, previous.text); return;
    }
    if (busy) throw new Error("A steering command is still being delivered. Wait before sending another.");
    if (receipts.size >= 1000) throw new Error("Steering history is full. Reload the Notify extension before sending more.");
    receipts.set(id, { action: String(value.action), status: "sending", text: "Delivering to Copilot...", message: value.text, agentID });
    busy = true;
    let interrupted = false;
    try {
      if (agentID) {
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
      if (receipts.get(id)?.status !== "received") {
        status(id, "unknown", `${interrupted ? "Main turn interrupted. " : ""}Delivery is uncertain; check the session before resending. ${String(error)}`);
      }
    } finally { busy = false; }
  };
  const unsubscribe = session.on(event => {
    if (event.type === "user.message" && !event.agentId && event.data.clientTurnId &&
        receipts.has(event.data.clientTurnId) && !receipts.get(event.data.clientTurnId)?.agentID) {
      status(event.data.clientTurnId, "received", "Received by Copilot. Agent activity is shown separately below.");
    }
  });
  return {
    stop() {
      stopped = true;
      unsubscribe();
      bridge.onControl = undefined;
      bridge.setCapabilities({ steering: false, sessionAutoYes: false, subagentChat: false, subagentStop: false });
    }
  };
}
