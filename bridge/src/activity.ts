import type { SessionEvent } from "@github/copilot-sdk";
import { object } from "./protocol.ts";

export interface ActivityEntry {
  id: string;
  kind: "user" | "assistant" | "reasoning" | "tool" | "status";
  title: string;
  detail: string;
  status: "running" | "complete" | "failed" | "info";
  timestamp: string;
  agentID?: string;
}

const bounded = (text: string) => text.length > 16000 ? text.slice(0, 15970) + "\n[Preview truncated]" : text;
const text = (value: unknown) => typeof value === "string" ? value : "";

export class ActivityFeed {
  private entries = new Map<string, ActivityEntry>();
  private dirty = new Set<string>();
  private timer?: NodeJS.Timeout;
  constructor(private publish: (entry: ActivityEntry) => void) {}

  receive(event: SessionEvent): void {
    let kind: ActivityEntry["kind"], title: string, detail = "", status: ActivityEntry["status"] = "complete";
    let key: string, delta = false;
    switch (event.type) {
      case "user.message":
        // Internal injected prompts are not user-authored conversation.
        if (event.data.source || event.data.isAutopilotContinuation) return;
        kind = "user"; title = "You"; key = event.data.messageId ?? event.id; detail = event.data.content; break;
      case "assistant.message":
        kind = "assistant"; title = "Agent response"; key = event.data.messageId; detail = event.data.content; break;
      case "assistant.message_delta":
        kind = "assistant"; title = "Agent response"; key = event.data.messageId; detail = event.data.deltaContent; delta = true; status = "running"; break;
      case "assistant.reasoning":
        kind = "reasoning"; title = "Published reasoning"; key = event.data.reasoningId; detail = event.data.content; break;
      case "assistant.reasoning_delta":
        kind = "reasoning"; title = "Published reasoning"; key = event.data.reasoningId; detail = event.data.deltaContent; delta = true; status = "running"; break;
      case "tool.execution_start": {
        kind = "tool"; title = event.data.toolTitle || event.data.toolName; key = event.data.toolCallId; status = "running";
        const args = event.data.arguments;
        if (object(args)) detail = ["description", "command", "path", "file_path", "pattern"]
          .filter(name => typeof args[name] === "string").map(name => `${name}: ${bounded(text(args[name]))}`).join("\n");
        break;
      }
      case "tool.execution_complete":
        kind = "tool"; title = "Tool result"; key = event.data.toolCallId; status = event.data.success ? "complete" : "failed";
        detail = event.data.error?.message ?? event.data.result?.content ?? "No output supplied.";
        break;
      case "session.idle":
        kind = "status"; title = "Agent idle"; key = event.id; status = "info";
        detail = "The agent is idle. This does not confirm the task or tests succeeded."; break;
      default: return;
    }
    if (!key || key.length > 128 || !title || typeof detail !== "string") return;
    if (!delta && !["tool", "status"].includes(kind) && !detail.trim()) return;
    const id = `${event.agentId ?? "main"}:${kind}:${key}`;
    if (id.length > 256 || (event.agentId?.length ?? 0) > 128) return;
    const previous = this.entries.get(id);
    if (delta && previous?.status === "complete") return;
    if (event.type === "tool.execution_complete" && previous) {
      if (previous.status !== "running") return;
      title = previous.title;
      const command = previous.detail.length > 6000 ? previous.detail.slice(0, 5970) + "\n[Command preview truncated]" : previous.detail;
      detail = `${command}\n\nResult:\n${detail}`;
    }
    const entry: ActivityEntry = {
      id, kind, title: title.slice(0, 300), detail: bounded(delta ? (previous?.detail ?? "") + detail : detail),
      status, timestamp: previous?.timestamp ?? event.timestamp, ...(event.agentId ? { agentID: event.agentId } : {})
    };
    this.entries.set(id, entry);
    this.dirty.add(id);
    let size = [...this.entries.values()].reduce((n, item) => n + Buffer.byteLength(item.detail) + 1024, 0);
    while (this.entries.size > 300 || size > 524288) {
      const first = this.entries.keys().next().value!;
      size -= Buffer.byteLength(this.entries.get(first)!.detail) + 1024;
      this.entries.delete(first); this.dirty.delete(first);
    }
    if (!this.timer) this.timer = setTimeout(() => this.flush(), 100);
  }
  flush(): void {
    clearTimeout(this.timer); this.timer = undefined;
    for (const id of this.dirty) {
      const entry = this.entries.get(id);
      if (entry && entry.detail.trim()) this.publish(entry);
    }
    this.dirty.clear();
  }
  stop(): void { this.flush(); this.entries.clear(); }
}
