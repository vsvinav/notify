#!/usr/bin/env node
import { createServer, createConnection, type Socket } from "node:net";
import { mkdirSync, lstatSync, readFileSync, writeFileSync, unlinkSync, chmodSync } from "node:fs";
import { open, constants } from "node:fs/promises";
import { chdir } from "node:process";
import { join, basename } from "node:path";
import { homedir } from "node:os";
import { createHash, randomUUID } from "node:crypto";
import { spawn, execFileSync } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import type { PermissionUpdate } from "@anthropic-ai/claude-agent-sdk";
import { Bridge } from "./connection.ts";
import { ClaudeTeam } from "./claude-team.ts";
import { object, claudeQuestions, validateReply, type Request, type Reply } from "./protocol.ts";
import { claudePermissionOptions } from "./permission-options.ts";
import { boundActivityText } from "./activity.ts";

const SOCKET_DIR = join(homedir(), "Library", "Application Support", "Notify", "claude");
const MAX_FRAME = 1_048_576;
const PERMISSION_TIMEOUT = 120_000;
const EVENTS = new Set(["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
  "PostToolUseFailure", "PermissionRequest", "Stop", "SubagentStart", "SubagentStop", "SessionEnd"]);

function socketName(sessionID: string): string {
  return createHash("sha256").update(sessionID).digest("hex").slice(0, 16) + ".sock";
}

function deriveSessionUUID(sessionID: string): string {
  const hex = createHash("sha256").update("notify-" + sessionID).digest("hex");
  return `${hex.slice(0,8)}-${hex.slice(8,12)}-4${hex.slice(13,16)}-${((parseInt(hex.slice(16,18),16)&0x3f)|0x80).toString(16).padStart(2,"0")}${hex.slice(18,20)}-${hex.slice(20,32)}`;
}

function privateSocketDirectory(): void {
  mkdirSync(SOCKET_DIR, { recursive: true, mode: 0o700 });
  const info = lstatSync(SOCKET_DIR);
  if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid?.() || (info.mode & 0o077)) {
    throw new Error("Unsafe Claude hook directory.");
  }
  chdir(SOCKET_DIR); // Short relative names also work under long macOS home paths.
}

async function connectHook(name: string): Promise<Socket> {
  return new Promise((resolve, reject) => {
    const socket = createConnection(name);
    socket.once("connect", () => { socket.removeListener("error", reject); resolve(socket); });
    socket.once("error", reject);
  });
}

function hookOwnerPID(): number | undefined {
  let pid = process.ppid;
  for (let depth = 0; depth < 16 && pid > 1; depth++) {
    let line: string;
    try {
      line = execFileSync("/bin/ps", ["-o", "pid=,ppid=,uid=,comm=", "-p", String(pid)],
        { encoding: "utf8", timeout: 1000, stdio: ["ignore", "pipe", "ignore"] }).trim();
    } catch {
      // macOS sandboxed hosts forbid ps; our installed exec hook keeps the direct parent.
      return pid;
    }
    const match = /^(\d+)\s+(\d+)\s+(\d+)\s+(.+)$/.exec(line);
    if (!match || Number(match[1]) !== pid || Number(match[3]) !== process.getuid?.()) return;
    // Command shells can remain around an exec hook and disappear as soon as it returns.
    if (!["sh", "bash", "zsh", "dash", "ksh", "fish"].includes(basename(match[4]).replace(/^-/, ""))) return pid;
    pid = Number(match[2]);
  }
}

async function hookMode(): Promise<void> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size > MAX_FRAME) return;
    chunks.push(Buffer.from(chunk));
  }
  let event: unknown;
  try { event = JSON.parse(Buffer.concat(chunks).toString("utf8")); } catch { return; }
  if (!object(event) || typeof event.session_id !== "string" || !event.session_id ||
      event.session_id.length > 256 || !EVENTS.has(String(event.hook_event_name))) return;
  privateSocketDirectory();
  const name = socketName(event.session_id);
  let socket: Socket;
  try { socket = await connectHook(name); }
  catch {
    if (event.hook_event_name === "SessionEnd") return;
    const ownerPID = hookOwnerPID();
    if (!ownerPID) return;
    // Every installed event can attach an already-open session after explicit hook reload.
    const child = spawn(process.execPath, [process.argv[1], "--serve", event.session_id,
      typeof event.cwd === "string" ? event.cwd : process.cwd(), String(ownerPID),
      typeof event.transcript_path === "string" ? event.transcript_path : ""],
      { detached: true, stdio: "ignore", cwd: SOCKET_DIR });
    child.on("error", () => {});
    child.unref();
    let connected: Socket | undefined;
    for (let attempt = 0; attempt < 40; attempt++) {
      await sleep(50);
      try { connected = await connectHook(name); break; } catch {}
    }
    if (!connected) return; // No decision: Claude retains its ordinary permission flow.
    socket = connected;
  }
  await new Promise<void>(resolve => {
    let buffer = Buffer.alloc(0), responded = false;
    const finish = () => { clearTimeout(timer); socket.destroy(); resolve(); };
    const timer = setTimeout(finish, event.hook_event_name === "PermissionRequest" ? PERMISSION_TIMEOUT : 10_000);
    socket.on("error", finish);
    socket.on("close", finish);
    process.stdout.on("error", finish);
    socket.on("data", chunk => {
      if (responded) return;
      buffer = Buffer.concat([buffer, chunk]);
      if (buffer.length > MAX_FRAME) { finish(); return; }
      const end = buffer.indexOf(10);
      if (end < 0) return;
      responded = true;
      const response = buffer.subarray(0, end).toString("utf8");
      if (!response || response === "{}") { finish(); return; }
      // ACK means stdout delivery, not acceptance by Claude's permission engine.
      process.stdout.write(response + "\n", error => {
        if (error) { finish(); return; }
        socket.end('{"ack":true}\n');
      });
    });
    socket.write(JSON.stringify(event) + "\n");
  });
}

function claimDaemon(name: string): (() => void) | undefined {
  const lock = name + ".lock";
  try { writeFileSync(lock, String(process.pid), { flag: "wx", mode: 0o600 }); }
  catch (error) {
    if (!object(error) || error.code !== "EEXIST") throw error;
    const info = lstatSync(lock);
    if (!info.isFile() || info.uid !== process.getuid?.() || (info.mode & 0o077)) return;
    const owner = Number(readFileSync(lock, "utf8"));
    if (!Number.isInteger(owner) || owner <= 1) return;
    try { process.kill(owner, 0); return; }
    catch (error) { if (!object(error) || error.code !== "ESRCH") return; }
    // Do not remove a lock replaced by another concurrently starting hook.
    if (lstatSync(lock).ino !== info.ino) return;
    unlinkSync(lock);
    try { writeFileSync(lock, String(process.pid), { flag: "wx", mode: 0o600 }); } catch { return; }
  }
  try {
    const info = lstatSync(name);
    if (!info.isSocket() || info.uid !== process.getuid?.()) throw new Error("Unsafe Claude hook socket.");
    unlinkSync(name);
  } catch (error) {
    if (!object(error) || error.code !== "ENOENT") { unlinkSync(lock); throw error; }
  }
  return () => {
    try { unlinkSync(name); } catch {}
    try { if (readFileSync(lock, "utf8") === String(process.pid)) unlinkSync(lock); } catch {}
  };
}

type Waiting = { socket: Socket; request: Request; input: Record<string, unknown>;
  suggestions?: PermissionUpdate[]; reply?: Reply };

async function daemonMode(sessionID: string, cwd: string, ownerPID: number, transcript: string): Promise<void> {
  if (!Number.isInteger(ownerPID) || ownerPID <= 1) throw new Error("Missing live Claude owner.");
  process.kill(ownerPID, 0);
  privateSocketDirectory();
  const name = socketName(sessionID);
  const release = claimDaemon(name);
  if (!release) return;
  const bridge = new Bridge("claude", cwd, undefined, deriveSessionUUID(sessionID), false);
  const team = new ClaudeTeam(bridge);
  const waiting = new Map<string, Waiting>();
  const sockets = new Set<Socket>();
  const controller = new AbortController();
  let stopped = false;
  bridge.enableActivity();
  bridge.setCapabilities({ steering: false, sessionAutoYes: false, subagentChat: false, subagentStop: false,
    subagentCreate: false, subagentRemove: false });
  bridge.setTitle("", sessionID);
  bridge.setState("ready", "Claude hooks connected; controls remain in the original terminal.");
  bridge.team({ agents: [], runningCount: 0, idleCount: 0, truncated: false,
    error: "Only subagents observed since these hooks connected are shown." });

  bridge.onReply = async value => {
    if (!object(value) || typeof value.requestID !== "string") return false;
    const pending = waiting.get(value.requestID);
    if (!pending || pending.reply || pending.socket.destroyed || !validateReply(pending.request, value) || value.automatic) return false;
    const decision = value.decision === "deny"
      ? { behavior: "deny", message: value.feedback?.trim() || "User declined in Notify." }
      : { behavior: "allow", updatedInput: pending.request.kind === "question"
          ? { ...pending.input, answers: Object.fromEntries(pending.request.questions.map(q =>
            [q.text, value.answers![q.id].join(", ")])) } : pending.input,
        ...(value.permissionOptionID ? { updatedPermissions: pending.suggestions } : {}) };
    pending.reply = value;
    pending.socket.setTimeout(5000, () => pending.socket.destroy());
    pending.socket.write(JSON.stringify({ hookSpecificOutput: { hookEventName: "PermissionRequest", decision } }) + "\n");
    return true;
  };

  function stop(): void {
    if (stopped) return;
    stopped = true;
    clearInterval(watchdog);
    controller.abort();
    for (const socket of sockets) socket.destroy();
    waiting.clear();
    bridge.pending.discardAll();
    bridge.stop();
    team.stop();
    server.close();
    release!();
  }

  const server = createServer(socket => {
    if (sockets.size >= 128) { socket.destroy(); return; }
    sockets.add(socket);
    socket.setTimeout(10_000, () => socket.destroy());
    let buffer = Buffer.alloc(0), requestID: string | undefined, received = false;
    socket.on("error", () => {});
    socket.on("close", () => {
      sockets.delete(socket);
      if (requestID && waiting.delete(requestID)) bridge.pending.cancel(requestID);
    });
    socket.on("data", chunk => {
      buffer = Buffer.concat([buffer, chunk]);
      if (buffer.length > MAX_FRAME) { socket.destroy(); return; }
      let end: number;
      while ((end = buffer.indexOf(10)) >= 0) {
        const line = buffer.subarray(0, end).toString("utf8");
        buffer = buffer.subarray(end + 1);
        let event: unknown;
        try { event = JSON.parse(line); } catch { socket.end("{}\n"); return; }
        if (!object(event)) { socket.end("{}\n"); return; }
        if (received) {
          const pending = requestID ? waiting.get(requestID) : undefined;
          if (event.ack === true && pending?.reply) {
            waiting.delete(requestID!);
            bridge.pending.reply(pending.reply);
            socket.end();
          } else socket.destroy();
          return;
        }
        received = true;
        if (event.session_id !== sessionID) { socket.end("{}\n"); return; }
        const hook = String(event.hook_event_name);
        if (hook === "PermissionRequest") {
          if (waiting.size >= 64 || typeof event.tool_name !== "string" || !object(event.tool_input)) {
            socket.end("{}\n"); return;
          }
          const question = event.tool_name === "AskUserQuestion";
          let questions: Request["questions"] = [], options: Request["permissionOptions"] = [];
          try {
            questions = question ? claudeQuestions(event.tool_input) : [];
            options = question ? [] : claudePermissionOptions(event.permission_suggestions as PermissionUpdate[] | undefined);
          } catch { socket.end("{}\n"); return; }
          const request: Request = {
            id: randomUUID(), kind: question ? "question" : "permission",
            title: question ? "Claude needs your answer" : `Allow ${event.tool_name.slice(0, 200)}?`,
            detail: question ? "" : JSON.stringify(event.tool_input, null, 2).slice(0, 120_000),
            autoEligible: false, supportsFeedback: !question, questions, permissionOptions: options
          };
          requestID = request.id;
          waiting.set(request.id, { socket, request, input: event.tool_input,
            ...(options.length ? { suggestions: event.permission_suggestions as PermissionUpdate[] } : {}) });
          socket.setTimeout(PERMISSION_TIMEOUT, () => socket.destroy());
          bridge.offer(request);
          return;
        }
        if (hook === "UserPromptSubmit") bridge.setState("working", "Processing prompt…");
        if (hook === "Stop") bridge.setState("ready", "Claude finished responding.");
        if (hook === "SubagentStart") team.started(event);
        if (hook === "SubagentStop") team.stopped(event);
        if (["PreToolUse", "PostToolUse", "PostToolUseFailure"].includes(hook) &&
            typeof event.tool_use_id === "string" && event.tool_use_id.length <= 128) {
          bridge.activity({ id: event.tool_use_id, kind: "tool",
            title: String(event.tool_name ?? "Tool").slice(0, 200),
            detail: hook === "PostToolUseFailure" ? boundActivityText(String(event.error ?? "Tool failed")) : "",
            status: hook === "PreToolUse" ? "running" : hook === "PostToolUseFailure" ? "failed" : "complete",
            timestamp: new Date().toISOString(),
            ...(typeof event.agent_id === "string" ? { agentID: event.agent_id.slice(0, 128) } : {}) });
        }
        socket.end("{}\n", () => { if (hook === "SessionEnd") stop(); });
      }
    });
  });
  server.on("error", stop);
  server.listen(name, () => { chmodSync(name, 0o600); void bridge.start(); });
  if (transcript) void followTranscript(transcript, bridge, sessionID, controller.signal);
  const watchdog = setInterval(() => {
    try { process.kill(ownerPID, 0); } catch { stop(); }
  }, 5000);
  process.once("SIGTERM", stop);
  process.once("SIGINT", stop);
}

async function followTranscript(path: string, bridge: Bridge, sessionID: string, signal: AbortSignal): Promise<void> {
  let offset = 0, started = false, skipping = false;
  let partial = Buffer.alloc(0), identity = "";
  const seen = new Set<string>();
  while (!signal.aborted) {
    try { await sleep(1000, undefined, { signal }); } catch { return; }
    try {
      const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
      try {
        const info = await file.stat();
        if (!info.isFile() || info.uid !== process.getuid?.()) continue;
        const nextIdentity = `${info.dev}:${info.ino}`;
        if (identity !== nextIdentity || info.size < offset) { offset = 0; partial = Buffer.alloc(0); started = false; }
        identity = nextIdentity;
        if (!started) {
          started = true;
          offset = Math.max(0, info.size - 256 * 1024);
          skipping = offset > 0;
        }
        const buffer = Buffer.alloc(Math.min(Math.max(0, info.size - offset), 65_536));
        const { bytesRead } = await file.read(buffer, 0, buffer.length, offset);
        offset += bytesRead;
        partial = Buffer.concat([partial, buffer.subarray(0, bytesRead)]);
        let end: number;
        while ((end = partial.indexOf(10)) >= 0) {
          const line = partial.subarray(0, end).toString("utf8");
          partial = partial.subarray(end + 1);
          if (skipping) { skipping = false; continue; }
          let entry: unknown;
          try { entry = JSON.parse(line); } catch { continue; }
          if (object(entry) && !signal.aborted) processTranscriptEntry(entry, bridge, sessionID, seen);
        }
        if (partial.length > MAX_FRAME) { partial = Buffer.alloc(0); skipping = true; }
      } finally { await file.close(); }
    } catch { /* A transcript may not exist until the first turn is saved. */ }
  }
}

function processTranscriptEntry(entry: Record<string, unknown>, bridge: Bridge, sessionID: string, seen: Set<string>): void {
  if (entry.type === "custom-title" || entry.type === "ai-title") {
    const title = entry.type === "custom-title" ? entry.customTitle : entry.aiTitle;
    if (typeof title === "string" && title.trim()) bridge.setTitle(title, sessionID);
    return;
  }
  if (entry.type !== "assistant" || entry.isSidechain === true || entry.parentToolUseId || entry.parent_tool_use_id) return;
  if (!object(entry.message) || !Array.isArray(entry.message.content)) return;
  const text = entry.message.content.filter(block => object(block) && block.type === "text" && typeof block.text === "string")
    .map(block => block.text).join("\n");
  if (!text.trim()) return;
  const id = typeof entry.uuid === "string" ? entry.uuid : randomUUID();
  if (seen.has(id)) return;
  seen.add(id);
  if (seen.size > 1000) seen.delete(seen.values().next().value!);
  bridge.activity({ id, kind: "assistant", title: "Agent response", detail: boundActivityText(text),
    status: "complete", timestamp: typeof entry.timestamp === "string" ? entry.timestamp : new Date().toISOString() });
}

const args = process.argv.slice(2);
if (args[0] === "--serve") {
  const [, sessionID, cwd, pid, transcript] = args;
  if (!sessionID || !cwd) process.exitCode = 1;
  else void daemonMode(sessionID, cwd, Number(pid), transcript ?? "").catch(() => { process.exitCode = 1; });
} else {
  void hookMode().catch(() => { process.exitCode = 0; });
}
