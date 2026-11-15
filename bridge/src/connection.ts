import { connect, type Socket } from "node:net";
import { readFile, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { PendingRequests } from "./pending.ts";
import { object, type Request, type Reply } from "./protocol.ts";
import type { ActivityEntry } from "./activity.ts";
import type { SubagentTeam } from "./subagents.ts";

export const discoveryPath = join(homedir(), "Library", "Application Support", "Notify", "connection.json");

export class Bridge {
  readonly pending = new PendingRequests();
  onReply: (value: unknown) => boolean | Promise<boolean> = value => this.pending.submit(value);
  onControl?: (value: unknown) => Promise<void>;
  private socket?: Socket;
  private timer?: NodeJS.Timeout;
  private stopped = false;
  private state = "ready";
  private lastText = "";
  private title?: string;
  private sourceSessionID?: string;
  private warned = false;
  private capabilities = { steering: false, sessionAutoYes: false, subagentChat: false, subagentStop: false };
  private receipts = new Map<string, { status: string; text: string }>();
  private activities = new Map<string, ActivityEntry>();
  private activityFeed = false;
  private teamSnapshot?: SubagentTeam;

  constructor(readonly agent: string, readonly cwd: string, private readonly connectionFile = discoveryPath,
    readonly sessionID: string = randomUUID(), private readonly terminalChat = true) {
    this.pending.onResolved = reply => this.send({ ...reply, type: "resolved" });
  }

  async start(): Promise<void> {
    if (this.stopped) return;
    try {
      const info = await stat(this.connectionFile);
      if ((info.mode & 0o077) !== 0 || info.uid !== process.getuid?.()) throw new Error("Insecure Notify connection file");
      const config: unknown = JSON.parse(await readFile(this.connectionFile, "utf8"));
      if (!object(config) || typeof config.token !== "string" || !Number.isInteger(config.port) ||
        typeof config.port !== "number" || config.port < 1 || config.port > 65535) throw new Error("Invalid Notify connection file");
      const socket = connect({ host: "127.0.0.1", port: config.port });
      this.socket = socket;
      let buffer = Buffer.alloc(0);
      let welcomed = false;
      socket.setTimeout(5000, () => {
        if (!welcomed) socket.destroy(new Error("Notify handshake timed out"));
      });
      socket.on("connect", () => {
        this.send({ type: "hello", token: config.token, agent: this.agent, cwd: this.cwd, pid: process.pid });
      });
      socket.on("data", data => {
        buffer = Buffer.concat([buffer, data]);
        if (buffer.length > 1_048_576) return socket.destroy(new Error("Notify frame too large"));
        let end: number;
        while ((end = buffer.indexOf(10)) >= 0) {
          const line = buffer.subarray(0, end).toString("utf8");
          buffer = buffer.subarray(end + 1);
          try {
            const message: unknown = JSON.parse(line);
            if (!object(message) || message.sessionID !== this.sessionID) throw new Error("Invalid Notify message");
            if (message.type === "welcome") {
              welcomed = true;
              socket.setTimeout(0);
              this.warned = false;
              this.send({ type: "state", state: this.state, text: this.lastText });
              if (this.title !== undefined) this.send({ type: "metadata", title: this.title, sourceSessionID: this.sourceSessionID });
              this.send({ type: "capabilities", ...this.capabilities, activityFeed: this.activityFeed });
              if (this.teamSnapshot) this.send({ type: "team", team: this.teamSnapshot });
              for (const activity of this.activities.values()) this.send({ type: "activity", activity });
              for (const [commandID, receipt] of this.receipts) this.send({ type: "control_status", commandID, ...receipt });
              for (const request of this.pending.requests) this.send({ type: "request", request });
            } else if (message.type === "reply") {
              void this.receiveReply(message);
            } else if (message.type === "control") {
              void this.receiveControl(message);
            }
          } catch (error) {
            socket.destroy(error instanceof Error ? error : new Error(String(error)));
            return;
          }
        }
      });
      socket.on("error", error => this.warn(error.message));
      socket.on("close", () => {
        if (this.socket === socket) this.socket = undefined;
        this.warn("App disconnected");
        this.retry();
      });
    } catch (error) {
      this.warn(error instanceof Error ? error.message : String(error));
      this.retry();
    }
  }

  private async receiveReply(message: unknown): Promise<void> {
    try {
      if (!await this.onReply(message)) throw new Error("Reply rejected: request expired, already sending, or answer invalid.");
    } catch (error) { this.error(error, object(message) && typeof message.requestID === "string" ? message.requestID : undefined); }
  }
  private async receiveControl(message: Record<string, unknown>): Promise<void> {
    try {
      if (!this.onControl) throw new Error("Remote steering is unavailable in this launcher.");
      await this.onControl(message);
    } catch (error) {
      const text = error instanceof Error ? error.message : String(error);
      if (typeof message.commandID === "string" && message.commandID.length <= 128) {
        this.controlStatus(message.commandID, "failed", text);
      } else this.error(text);
    }
  }
  setCapabilities(value: { steering: boolean; sessionAutoYes: boolean; subagentChat?: boolean; subagentStop?: boolean }): void {
    this.capabilities = { ...value, subagentChat: value.subagentChat === true, subagentStop: value.subagentStop === true };
    this.send({ type: "capabilities", ...this.capabilities, activityFeed: this.activityFeed });
  }
  enableActivity(): void { this.activityFeed = true; this.setCapabilities(this.capabilities); }
  team(snapshot: SubagentTeam): void {
    this.teamSnapshot = snapshot;
    this.send({ type: "team", team: snapshot });
  }
  activity(entry: ActivityEntry): void {
    this.activities.set(entry.id, entry);
    let size = [...this.activities.values()].reduce((n, item) => n + Buffer.byteLength(item.detail) + 1024, 0);
    while (this.activities.size > 300 || size > 524288) {
      const first = this.activities.keys().next().value!;
      size -= Buffer.byteLength(this.activities.get(first)!.detail) + 1024;
      this.activities.delete(first);
    }
    this.send({ type: "activity", activity: entry });
  }
  controlStatus(commandID: string, status: string, text: string): void {
    this.receipts.set(commandID, { status, text: text.slice(0, 2000) });
    if (this.receipts.size > 100) this.receipts.delete(this.receipts.keys().next().value!);
    this.send({ type: "control_status", commandID, status, text: text.slice(0, 2000) });
  }
  private warn(reason: string): void {
    if (this.stopped || this.warned) return;
    this.warned = true;
    console.error(`\nNotify: ${reason}. Open Notify.app to reconnect; ${this.terminalChat ? "/reply still works in this terminal" : "use the original Copilot prompt in the meantime"}.`);
  }
  private retry(): void {
    if (!this.stopped) this.timer = setTimeout(() => { void this.start(); }, 3000);
  }
  private send(message: Record<string, unknown>): void {
    if (this.socket && !this.socket.destroyed && this.socket.readyState === "open") {
      this.socket.write(JSON.stringify({ ...message, sessionID: this.sessionID }) + "\n");
    }
  }
  setState(state: string, text = ""): void {
    this.state = state;
    this.lastText = text.slice(-4000);
    this.send({ type: "state", state, text: this.lastText });
  }
  setTitle(title: string, sourceSessionID = this.sessionID): void {
    this.title = title.trim().slice(0, 300);
    this.sourceSessionID = sourceSessionID;
    this.send({ type: "metadata", title: this.title, sourceSessionID });
  }
  output(text: string): void {
    if (this.terminalChat) process.stdout.write(text);
    if (!this.activityFeed) this.send({ type: "output", text: text.slice(-16000) });
  }
  error(error: unknown, requestID?: string): void {
    const text = error instanceof Error ? error.message : String(error);
    console.error(`\nNotify: ${text}`);
    this.setState("error", text);
    this.send({ type: "error", text, requestID });
  }
  offer(request: Request): void {
    if (this.stopped) throw new Error("Notify bridge is stopped");
    void this.pending.add(request);
    this.send({ type: "request", request });
  }
  async ask(request: Omit<Request, "id">, signal?: AbortSignal, beforeReply?: (reply: Reply) => Promise<void>): Promise<Reply> {
    const full = { ...request, id: randomUUID() };
    if (this.stopped) return { requestID: full.id, decision: "deny" };
    const result = this.pending.add(full, signal, beforeReply);
    if (!signal?.aborted) {
      console.log(`\n[Needs you: ${full.id.slice(0, 8)}] ${full.title}\n${full.detail}`);
      for (const q of full.questions) console.log(`${q.id}: ${q.text}\n  ${q.options.map(o => o.label).join(" | ")}`);
      console.log(`Reply in Notify, or /reply ${full.id.slice(0, 8)} ${full.kind === "permission" ? "allow|deny" : '\'{"0":["your answer"]}\''}`);
      this.send({ type: "request", request: full });
    }
    return result;
  }
  terminalReply(line: string): void {
    const match = /^\/reply\s+(\S+)\s+([\s\S]+)$/.exec(line);
    if (!match) throw new Error('Use /reply <request-id> allow|deny, or /reply <request-id> {"0":["answer"]}');
    const matches = this.pending.requests.filter(request => request.id.startsWith(match[1]));
    if (matches.length !== 1) throw new Error("Request ID is missing, ambiguous, or already answered");
    const action = match[2].trim();
    const reply = action === "allow" || action === "deny"
      ? { requestID: matches[0].id, decision: action, automatic: false }
      : { requestID: matches[0].id, decision: "answer", answers: JSON.parse(action), automatic: false };
    if (!this.pending.reply(reply)) throw new Error("Invalid answer. Answer every question using its numeric ID.");
  }
  stop(): void {
    this.stopped = true;
    clearTimeout(this.timer);
    this.pending.cancelAll();
    this.socket?.end();
  }
}
