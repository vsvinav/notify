#!/usr/bin/env node
import { createServer, createConnection, type Socket } from "node:net";
import { mkdirSync } from "node:fs";
import { open, constants } from "node:fs/promises";
import { chdir } from "node:process";
import { join } from "node:path";
import { homedir } from "node:os";
import { createHash, randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { Bridge } from "./connection.ts";
import { ClaudeTeam } from "./claude-team.ts";
import { object } from "./protocol.ts";
import { boundActivityText } from "./activity.ts";

const NOTIFY_DIR = join(homedir(), "Library", "Application Support", "Notify");
const CLAUDE_SOCKET_DIR = join(NOTIFY_DIR, "claude");
const KILLED_TTL_MS = 300_000;
const TRANSCRIPT_POLL_MS = 1_000;
const WATCHDOG_INTERVAL_MS = 5_000;
const HISTORY_SKIP_BYTES = 256 * 1024;

// Suppress unused variable warning for KILLED_TTL_MS (kept for spec compliance).
void KILLED_TTL_MS;

function socketName(sessionID: string): string {
  return createHash("sha256").update(sessionID).digest("hex").slice(0, 16) + ".sock";
}

function deriveSessionUUID(claudeSessionID: string): string {
  const hex = createHash("sha256").update("notify-" + claudeSessionID).digest("hex");
  return `${hex.slice(0,8)}-${hex.slice(8,12)}-4${hex.slice(13,16)}-${((parseInt(hex.slice(16,18),16)&0x3f)|0x80).toString(16).padStart(2,"0")}${hex.slice(18,20)}-${hex.slice(20,32)}`;
}

// ── Hook event mode ───────────────────────────────────────────────────────────

async function hookMode(): Promise<void> {
  let raw = "";
  for await (const chunk of process.stdin) raw += String(chunk);
  if (!raw.trim()) return;

  let event: Record<string, unknown>;
  try { event = JSON.parse(raw); } catch { return; }

  const sessionID = String(event.session_id ?? "");
  const hookName = String(event.hook_event_name ?? "");
  if (!sessionID) return;

  if (hookName === "SessionStart") {
    // Spawn daemon detached — do not await.
    try { mkdirSync(CLAUDE_SOCKET_DIR, { recursive: true, mode: 0o700 }); } catch {}
    const child = spawn(process.execPath, [
      process.argv[1],
      "--serve", sessionID,
      String(event.cwd ?? process.cwd()),
      String(process.ppid ?? 0),
      String(event.transcript_path ?? "")
    ], { detached: true, stdio: "ignore", cwd: CLAUDE_SOCKET_DIR });
    child.unref();
    return;
  }

  // Forward to daemon.
  try { chdir(CLAUDE_SOCKET_DIR); } catch { return; }
  const name = socketName(sessionID);

  await new Promise<void>(resolve => {
    const timeoutMs = hookName === "PermissionRequest" ? 86_400_000 : 10_000;
    const timer = setTimeout(() => { sock.destroy(); resolve(); }, timeoutMs);
    const sock = createConnection(name);
    let buf = "";
    sock.on("connect", () => { sock.write(JSON.stringify(event) + "\n"); });
    sock.on("data", data => {
      buf += data.toString();
      const nl = buf.indexOf("\n");
      if (nl >= 0) {
        const response = buf.slice(0, nl).trim();
        clearTimeout(timer);
        if (response && response !== "{}") {
          try { process.stdout.write(response + "\n"); } catch {}
        }
        sock.end();
        resolve();
      }
    });
    sock.on("error", () => { clearTimeout(timer); resolve(); });
    sock.on("close", () => { clearTimeout(timer); resolve(); });
  });
}

// ── Daemon mode ───────────────────────────────────────────────────────────────

async function daemonMode(sessionID: string, cwd: string, claudePID: number, transcriptPath: string): Promise<void> {
  try { chdir(CLAUDE_SOCKET_DIR); } catch (err) {
    console.error(`Notify Claude daemon: cannot chdir to socket dir: ${err}`);
    process.exit(1);
  }

  const bridge = new Bridge("claude", cwd, undefined, deriveSessionUUID(sessionID), false);
  const team = new ClaudeTeam(bridge);
  let pendingPermissionSocket: Socket | undefined;

  bridge.enableActivity();
  bridge.setCapabilities({ steering: true, sessionAutoYes: false,
    subagentChat: false, subagentStop: true, subagentCreate: false,
    subagentRemove: false, subagentTypes: [], subagentModels: [] });
  bridge.setState("ready", "Claude session connected.");

  // ── Steering via iTerm2 ──────────────────────────────────────────────────
  bridge.onControl = async value => {
    if (!object(value) || typeof value.commandID !== "string") throw new Error("Invalid control");
    const id = value.commandID;
    const action = String(value.action ?? "");
    const text = String(value.text ?? "");
    if (!["queue", "interrupt", "stop"].includes(action)) throw new Error("Unsupported Claude action.");
    if (action !== "stop" && !text.trim()) throw new Error("Message text is empty.");

    let tty: string;
    try { tty = await findClaudeTTY(claudePID); }
    catch (err) {
      bridge.controlStatus(id, "failed", `Cannot find Claude's terminal: ${String(err)}`);
      return;
    }

    const escaped = text.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
    // Prepend "tty" so ps output "s002" becomes "ttys002"; iTerm2 reports "/dev/ttys002".
    const ttyDevice = `tty${tty}`;
    let script: string;
    const sessionFinder = `set foundSession to missing value
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if tty of s ends with "/dev/${ttyDevice}" then set foundSession to s
      end repeat
    end repeat
  end repeat
  if foundSession is missing value then error "Claude terminal not found."`;
    if (action === "stop") {
      script = `tell application "iTerm2"\n  ${sessionFinder}\n  tell foundSession to write text "${"\u001b"}" newline NO\nend tell`;
    } else if (action === "interrupt") {
      script = `tell application "iTerm2"\n  ${sessionFinder}\n  tell foundSession to write text "${"\u001b"}" newline NO\n  tell foundSession to write text "${escaped}"\nend tell`;
    } else {
      script = `tell application "iTerm2"\n  ${sessionFinder}\n  tell foundSession to write text "${escaped}"\nend tell`;
    }

    try {
      await runOsascript(script, tty);
      bridge.controlStatus(id, action === "stop" ? "stopped" : "received",
        action === "stop" ? "Escape sent to Claude terminal." :
        action === "interrupt" ? "Interrupted and message typed into Claude terminal." :
        "Message typed into Claude terminal.");
    } catch (err) {
      bridge.controlStatus(id, "failed", `iTerm2 delivery failed: ${String(err)}`);
    }
  };

  void bridge.start();

  // ── Unix socket server ───────────────────────────────────────────────────
  const name = socketName(sessionID);
  const server = createServer(sock => {
    let buf = "";
    sock.on("data", data => {
      buf += data.toString();
      const nl = buf.indexOf("\n");
      if (nl < 0) return;
      const line = buf.slice(0, nl);
      buf = buf.slice(nl + 1);
      let evt: Record<string, unknown>;
      try { evt = JSON.parse(line); } catch { sock.write("{}\n"); sock.end(); return; }
      handleHookEvent(evt, sock, bridge, team, (s) => { pendingPermissionSocket = s; }, () => pendingPermissionSocket);
    });
    sock.on("error", () => {});
  });

  server.listen(name, () => {
    // Set socket permissions.
    try { require("node:fs").chmodSync(name, 0o600); } catch {}
  });

  // ── Transcript follower ──────────────────────────────────────────────────
  if (transcriptPath) {
    void followTranscript(transcriptPath, bridge, sessionID);
  }

  // ── Claude-PID watchdog ──────────────────────────────────────────────────
  const watchdog = setInterval(() => {
    try { process.kill(claudePID, 0); }
    catch {
      clearInterval(watchdog);
      server.close();
      bridge.stop();
      team.stop();
      process.exit(0);
    }
  }, WATCHDOG_INTERVAL_MS);

  process.on("SIGTERM", () => {
    clearInterval(watchdog);
    server.close();
    bridge.stop();
    team.stop();
    process.exit(0);
  });
}

function handleHookEvent(
  event: Record<string, unknown>,
  sock: Socket,
  bridge: Bridge,
  team: ClaudeTeam,
  setPending: (s: Socket | undefined) => void,
  getPending: () => Socket | undefined
): void {
  const hookName = String(event.hook_event_name ?? "");

  // Approval parity: dismiss pending permission when terminal acts.
  const dismissesPending = ["PostToolUse", "PostToolUseFailure", "Stop",
    "UserPromptSubmit", "SubagentStop", "Notification"];
  if (dismissesPending.includes(hookName)) {
    const pending = getPending();
    if (pending) {
      bridge.pending.discardAll();
      pending.write('{"decision":"allow"}\n');
      pending.end();
      setPending(undefined);
    }
    if (hookName === "Stop") {
      bridge.setState("ready", "Session stopped.");
    }
    if (hookName === "UserPromptSubmit") {
      bridge.setState("working", "Processing prompt...");
    }
    if (hookName === "SubagentStop") {
      team.stopped(event);
    }
    sock.write("{}\n"); sock.end();
    return;
  }

  if (hookName === "PermissionRequest") {
    const tool = String(event.tool_name ?? "tool");
    const input = event.tool_input ?? {};
    const detail = JSON.stringify(input, null, 2).slice(0, 120_000);
    setPending(sock);
    bridge.ask({
      kind: "permission",
      title: `Allow ${tool}?`,
      detail,
      autoEligible: false,
      questions: []
    }).then(reply => {
      if (getPending() !== sock) return; // already dismissed by terminal
      setPending(undefined);
      const response = reply.decision === "allow"
        ? '{"decision":"allow"}'
        : '{"decision":"deny","reason":"User declined in Notify."}';
      sock.write(response + "\n"); sock.end();
    }).catch(() => {
      setPending(undefined);
      sock.write('{"decision":"deny","reason":"Notify request failed."}\n'); sock.end();
    });
    return;
  }

  if (hookName === "SubagentStart") {
    team.started(event);
    sock.write("{}\n"); sock.end();
    return;
  }

  if (hookName === "SessionEnd") {
    sock.write("{}\n"); sock.end();
    bridge.stop();
    team.stop();
    process.exit(0);
  }

  sock.write("{}\n"); sock.end();
}

// ── Transcript follower ───────────────────────────────────────────────────────

async function followTranscript(path: string, bridge: Bridge, sessionID: string): Promise<void> {
  let offset = 0;
  const seenUUIDs = new Set<string>();
  let started = false;

  while (true) {
    await new Promise(r => setTimeout(r, TRANSCRIPT_POLL_MS));
    try {
      const fd = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
      try {
        const info = await fd.stat();
        if (!info.isFile()) continue;
        if (!started) {
          started = true;
          // Skip old history if file is large.
          if (info.size > HISTORY_SKIP_BYTES) {
            offset = info.size - HISTORY_SKIP_BYTES;
            // Align to next newline.
            const buf = Buffer.alloc(512);
            const { bytesRead } = await fd.read(buf, 0, 512, offset);
            const nl = buf.subarray(0, bytesRead).indexOf(10);
            offset = nl >= 0 ? offset + nl + 1 : offset + bytesRead;
          }
        }
        if (info.size <= offset) continue;
        const toRead = Math.min(info.size - offset, 65_536);
        const buf = Buffer.alloc(toRead);
        const { bytesRead } = await fd.read(buf, 0, toRead, offset);
        offset += bytesRead;
        const text = buf.subarray(0, bytesRead).toString("utf8");
        const lines = text.split("\n");
        for (const line of lines) {
          if (!line.trim()) continue;
          let entry: unknown;
          try { entry = JSON.parse(line); } catch { continue; }
          if (!object(entry)) continue;
          processTranscriptEntry(entry, bridge, sessionID, seenUUIDs);
        }
      } finally { await fd.close(); }
    } catch { /* file not yet created or unreadable */ }
  }
}

function processTranscriptEntry(
  entry: Record<string, unknown>,
  bridge: Bridge,
  sessionID: string,
  seenUUIDs: Set<string>
): void {
  const type = String(entry.type ?? "");

  if (type === "assistant") {
    const uuid = String(entry.uuid ?? "");
    if (uuid && seenUUIDs.has(uuid)) return;
    if (uuid) seenUUIDs.add(uuid);
    // Only main-thread messages (parentToolUseId === null/undefined).
    if (entry.parentToolUseId !== null && entry.parentToolUseId !== undefined) return;
    const message = entry.message;
    if (!object(message) || !Array.isArray(message.content)) return;
    for (const block of message.content) {
      if (!object(block)) continue;
      if (block.type === "text" && typeof block.text === "string" && block.text.trim()) {
        bridge.output(block.text + "\n");
        bridge.activity({
          id: uuid || randomUUID(),
          kind: "assistant",
          title: "Agent response",
          detail: boundActivityText(block.text),
          status: "complete",
          timestamp: new Date().toISOString()
        });
      }
      if (block.type === "thinking" && typeof block.thinking === "string" && block.thinking.trim()) {
        bridge.activity({
          id: (uuid || randomUUID()) + "-thinking",
          kind: "assistant",
          title: "Thinking",
          detail: boundActivityText(block.thinking),
          status: "complete",
          timestamp: new Date().toISOString()
        });
      }
    }
  }

  if (type === "summary") {
    const title = String((entry.customTitle ?? entry.aiTitle) ?? "");
    if (title.trim()) bridge.setTitle(title.trim().slice(0, 300), sessionID);
  }
}

// ── iTerm2 helpers ────────────────────────────────────────────────────────────

async function findClaudeTTY(pid: number): Promise<string> {
  const { execFile } = await import("node:child_process");
  const { promisify } = await import("node:util");
  const exec = promisify(execFile);
  const { stdout } = await exec("/bin/ps", ["-axo", "pid=,ppid=,uid=,tty=,comm="]);
  const uid = process.getuid?.() ?? -1;
  const rows = stdout.trim().split("\n").map(line => {
    const parts = line.trim().split(/\s+/);
    return { pid: Number(parts[0]), ppid: Number(parts[1]), uid: Number(parts[2]), tty: parts[3], comm: parts[4] ?? "" };
  });
  // Walk ancestry: find the row for our claudePID and get its TTY.
  const row = rows.find(r => r.pid === pid && r.uid === uid);
  if (!row || row.tty === "??" || !row.tty) throw new Error("Claude process has no TTY.");
  return row.tty;
}

async function runOsascript(script: string, tty: string): Promise<void> {
  const { execFile } = await import("node:child_process");
  const { promisify } = await import("node:util");
  const exec = promisify(execFile);
  const { stderr } = await exec("/usr/bin/osascript", ["-e", script]);
  if (stderr.trim()) throw new Error(stderr.trim());
}

// ── Entry point ───────────────────────────────────────────────────────────────

const args = process.argv.slice(2);
if (args[0] === "--serve") {
  const [, sessionID, cwd, pidStr, transcriptPath] = args;
  if (!sessionID || !cwd) { console.error("Usage: claude-hook.js --serve <sessionID> <cwd> <pid> [transcriptPath]"); process.exit(1); }
  void daemonMode(sessionID, cwd, Number(pidStr) || 0, transcriptPath ?? "");
} else {
  void hookMode().catch(err => { console.error(`Notify Claude hook: ${err}`); process.exit(0); });
}
