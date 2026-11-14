import type { CopilotSession } from "@github/copilot-sdk";
import type { Bridge } from "./connection.ts";
import { object } from "./protocol.ts";

type Receipt = { action: string; status: string; text: string };

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
  bridge.setCapabilities({ steering: true, sessionAutoYes: true });
  bridge.onControl = async value => {
    if (stopped || !object(value) || typeof value.commandID !== "string" ||
        !/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(value.commandID) ||
        !["queue", "interrupt", "stop"].includes(String(value.action)) ||
        typeof value.text !== "string" || value.text.length > 16000 ||
        (value.action !== "stop" && !value.text.trim())) throw new Error("Invalid or unavailable steering command.");
    const id = value.commandID;
    const previous = receipts.get(id);
    if (previous) { bridge.controlStatus(id, previous.status, previous.text); return; }
    if (busy) throw new Error("A steering command is still being delivered. Wait before sending another.");
    if (receipts.size >= 1000) throw new Error("Steering history is full. Reload the Notify extension before sending more.");
    receipts.set(id, { action: String(value.action), status: "sending", text: "Delivering to Copilot..." });
    busy = true;
    let interrupted = false;
    try {
      if (value.action === "stop") {
        await session.abort();
        for (const [queuedID, receipt] of receipts) {
          if (queuedID !== id && receipt.status === "queued") status(queuedID, "cancelled", "Queue cleared by Stop.");
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
    if (event.type === "user.message" && !event.agentId && event.data.clientTurnId && receipts.has(event.data.clientTurnId)) {
      status(event.data.clientTurnId, "received", "Received by Copilot. Agent activity is shown separately below.");
    }
  });
  return {
    stop() {
      stopped = true;
      unsubscribe();
      bridge.onControl = undefined;
      bridge.setCapabilities({ steering: false, sessionAutoYes: false });
    }
  };
}
