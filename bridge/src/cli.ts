#!/usr/bin/env node
import { createInterface } from "node:readline";
import { parseArgs } from "node:util";
import { realpath } from "node:fs/promises";
import { Bridge } from "./connection.ts";
import { ClaudeAgent, CopilotAgent } from "./agents.ts";
import { setupCopilot } from "./setup.ts";
import { executable } from "./executable.ts";

async function main() {
  const { positionals, values } = parseArgs({
    allowPositionals: true,
    options: { model: { type: "string" }, resume: { type: "string" }, help: { type: "boolean", short: "h" }, doctor: { type: "boolean" } }
  });
  const name = positionals.shift();
  if (values.help || !name) {
    console.log("notify claude|copilot [--model NAME] [--resume ID] [prompt]\nnotify demo\nnotify setup-copilot\nnotify setup-claude\n\nSimple SDK terminal chat with native floating replies.\nsetup-copilot installs the Copilot extension.\nsetup-claude installs Claude Code hooks.\n/quit exits. /reply ID allow|deny answers permissions.\n/reply ID {\"0\":[\"answer\"]} answers questions. IDs can use their first eight characters.");
    return;
  }
  if (name === "setup-copilot") {
    if (positionals.length || values.model || values.resume || values.doctor) throw new Error("Usage: notify setup-copilot");
    const path = await setupCopilot();
    console.log(`Installed ${path}\n\nIf experimental mode is already enabled in an existing Copilot terminal:\n/extensions manage\n\nEnable notify, press Esc to close the manager, then approve its permission-access request. If it is not listed, ask Copilot to reload extensions.\n\nIMPORTANT: /settings experimental on restarts Copilot's UI/session initialization in CLI 1.0.112. Do not toggle it during active work. For future terminals, start copilot --experimental.\nNo running sessions or permission settings were changed by this installer.`);
    return;
  }
  if (name === "setup-claude") {
    if (positionals.length || values.model || values.resume || values.doctor) {
      throw new Error("Usage: notify setup-claude");
    }
    const { setupClaude } = await import("./setup.ts");
    const path = await setupClaude();
    console.log(`Installed hooks at ${path}\n\nFor existing Claude terminals: restart them or type /hooks in Claude to reload.\nFor new terminals: hooks load automatically.\n\nNo running sessions or permission settings were changed.`);
    return;
  }
  if (!["claude", "copilot", "demo", "setup-copilot", "setup-claude"].includes(name)) throw new Error("Choose claude, copilot, demo, setup-copilot, or setup-claude.");
  const bridge = new Bridge(name, await realpath(process.cwd()));
  const agent = name === "claude" ? new ClaudeAgent(bridge, await executable("claude"), values.model, values.resume)
    : name === "copilot" ? new CopilotAgent(bridge, await executable("copilot"), values.model, values.resume) : undefined;
  if (values.doctor) {
    try {
      if (agent instanceof CopilotAgent) await agent.start();
      if (agent instanceof ClaudeAgent) await agent.checkConnection();
      console.log(`${name}: installed runtime is reachable. No model prompt sent.`);
    } finally { await agent?.stop(); bridge.stop(); }
    return;
  }
  await bridge.start();
  const rl = createInterface({ input: process.stdin, output: process.stdout, prompt: "\nnotify> " });
  let busy = false;
  let closing = false;
  let endOnComplete = false;
  const stop = async () => {
    if (closing) return;
    closing = true;
    bridge.pending.discardAll();
    rl.close();
    try { await agent?.stop(); }
    catch (error) { console.error(error); process.exitCode = 1; }
    finally { bridge.stop(); }
  };
  const send = async (prompt: string) => {
    if (busy) { console.error("Agent is working. Answer pending requests, or use /quit to stop."); return; }
    busy = true;
    bridge.setState("working", prompt);
    try {
      if (agent) await agent.send(prompt);
      else {
        const response = await bridge.ask({
          kind: "permission", title: "Demo: allow this example command?",
          detail: "echo 'Hello from Notify'\n\nDemo only. No command will be executed.", autoEligible: false, questions: []
        });
        bridge.output(`\nDemo permission response: ${response.decision}\n`);
        const answer = await bridge.ask({
          kind: "question", title: "Demo: choose your database", detail: "This demonstrates real request/reply transport without model usage.",
          autoEligible: false, questions: [
            { id: "0", text: "Which database?", multiple: false, allowFreeform: true, options: [
              { label: "SQLite", description: "Local storage" }, { label: "PostgreSQL", description: "Shared database" }
            ] },
            { id: "1", text: "Which checks?", multiple: true, allowFreeform: true, options: [
              { label: "Unit", description: "" }, { label: "Integration", description: "" }
            ] }
          ]
        });
        bridge.output(`Demo question response: ${JSON.stringify(answer.answers ?? answer.decision)}\n`);
      }
      bridge.setState("ready", "Turn finished. Ready for your next task.");
    } catch (error) { bridge.error(error); }
    finally {
      busy = false;
      if (endOnComplete) await stop();
      else if (!closing) rl.prompt();
    }
  };
  rl.on("line", line => {
    const text = line.trim();
    if (!text) { if (!busy) rl.prompt(); return; }
    if (text === "/quit") { void stop(); return; }
    if (text.startsWith("/reply ")) {
      try { bridge.terminalReply(text); } catch (error) { console.error(error instanceof Error ? error.message : error); }
      return;
    }
    void send(text);
  });
  rl.on("close", () => {
    if (busy && !process.stdin.isTTY) endOnComplete = true;
    else void stop();
  });
  process.on("SIGINT", () => { void stop(); });
  process.on("SIGTERM", () => { void stop(); });
  console.log(`Notify / ${name} / ${bridge.cwd}\nUse the app for replies, or /reply in this terminal. /quit exits.`);
  if (name === "demo" || positionals.length) void send(positionals.join(" ") || "Demo");
  else rl.prompt();
}

main().catch(error => { console.error(`Notify: ${error instanceof Error ? error.message : error}`); process.exit(1); });
