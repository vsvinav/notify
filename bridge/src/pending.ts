import { validateReply, type Request, type Reply } from "./protocol.ts";

type Entry = {
  request: Request;
  resolve: (reply: Reply) => void;
  cleanup: () => void;
  beforeReply?: (reply: Reply) => Promise<void>;
  checking: boolean;
};

export class PendingRequests {
  private entries = new Map<string, Entry>();
  onResolved: (reply: Reply) => void = () => {};
  get requests(): Request[] { return [...this.entries.values()].map(entry => entry.request); }

  add(request: Request, signal?: AbortSignal, beforeReply?: (reply: Reply) => Promise<void>): Promise<Reply> {
    if (this.entries.has(request.id)) throw new Error("Duplicate request ID");
    return new Promise(resolve => {
      const abort = () => this.reply({ requestID: request.id, decision: "deny" });
      this.entries.set(request.id, { request, resolve, cleanup: () => signal?.removeEventListener("abort", abort), beforeReply, checking: false });
      signal?.addEventListener("abort", abort, { once: true });
      if (signal?.aborted) abort();
    });
  }

  reply(value: unknown): boolean {
    if (!value || typeof value !== "object" || !("requestID" in value) || typeof value.requestID !== "string") return false;
    const entry = this.entries.get(value.requestID);
    if (!entry || !validateReply(entry.request, value)) return false;
    if (value.permissionOptionID && entry.beforeReply) return false;
    return this.settle(entry, value);
  }

  async submit(value: unknown): Promise<boolean> {
    if (!value || typeof value !== "object" || !("requestID" in value) || typeof value.requestID !== "string") return false;
    const entry = this.entries.get(value.requestID);
    if (!entry || !validateReply(entry.request, value)) return false;
    if (!value.permissionOptionID || !entry.beforeReply) return this.reply(value);
    if (entry.checking) return false;
    entry.checking = true;
    try {
      await entry.beforeReply(value);
      if (this.entries.get(value.requestID) !== entry) return false;
      return this.settle(entry, value);
    } finally { entry.checking = false; }
  }

  private settle(entry: Entry, value: Reply): boolean {
    this.entries.delete(entry.request.id);
    entry.cleanup();
    entry.resolve(value);
    this.onResolved(value);
    return true;
  }

  cancelAll(): void {
    for (const request of this.requests) this.reply({ requestID: request.id, decision: "deny" });
  }
  cancel(id: string): void {
    this.reply({ requestID: id, decision: "deny", cancelled: true });
  }
  discardAll(): void {
    // shortcut: SDK 0.2.81 writes late results into closed transports. Discard ended
    // waiters without settling; revisit when the SDK handles callback teardown.
    for (const entry of this.entries.values()) {
      entry.cleanup();
      this.onResolved({ requestID: entry.request.id, decision: "deny", cancelled: true });
    }
    this.entries.clear();
  }
}
