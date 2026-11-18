import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer as httpServer } from "node:http";
import { createServer as socketServer } from "node:net";
import { spawn, execFileSync } from "node:child_process";
import { mkdtemp, mkdir, readFile, writeFile, rm, access } from "node:fs/promises";
import { join, resolve } from "node:path";
import { once } from "node:events";
import { setTimeout as sleep } from "node:timers/promises";
import { setupClaude } from "../dist/setup.js";
import { query } from "@anthropic-ai/claude-agent-sdk";

// This fixture has no real account: the sandbox permits only local sockets, and the
// child receives a new environment, fake API key and isolated Claude configuration.
for (const scenario of ["question", "allow", "deny", "headless-question"]) test(`installed Claude ${scenario} behavior against a local synthetic provider`,
  { timeout: 30000 }, async t => {
    const root = await mkdtemp(resolve(".claude-runtime-"));
    const home = join(root, "home"), config = join(home, ".claude");
    const notify = join(home, "Library", "Application Support", "Notify");
    await mkdir(notify, { recursive: true, mode: 0o700 });
    await mkdir(config, { recursive: true });
    const executable = process.env.NOTIFY_CLAUDE_EXECUTABLE ??
      execFileSync("/usr/bin/which", ["claude"], { encoding: "utf8" }).trim();
    const daemonPIDs = new Set(), nativeFrames = [], apiRequests = [], sockets = new Set();
    const question = scenario.endsWith("question");
    const api = httpServer(async (request, response) => {
      let body = "";
      for await (const chunk of request) body += chunk;
      if (request.url?.includes("count_tokens")) { response.end(JSON.stringify({ input_tokens: 10 })); return; }
      if (!request.url?.startsWith("/v1/messages")) { response.writeHead(404); response.end(); return; }
      const data = JSON.parse(body);
      apiRequests.push(data);
      assert.equal(request.headers["x-api-key"], "fixture-not-a-real-key");
      const tool = question ? "AskUserQuestion" : "Bash";
      const hasResult = data.messages.some(message => Array.isArray(message.content) &&
        message.content.some(block => block.type === "tool_result"));
      const input = question ? { questions: [{
        question: "Which fixture?", header: "Fixture", multiSelect: true,
        options: [{ label: "A", description: "First" }, { label: "B", description: "Second" }]
      }] } : { command: `touch ${scenario}-marker`, description: "Create only an isolated fixture marker" };
      const content = hasResult ? [{ type: "text", text: "Synthetic provider finished." }]
        : [{ type: "tool_use", id: "fixture-tool", name: tool, input }];
      const result = { id: "fixture-message", type: "message", role: "assistant", model: data.model,
        content, stop_reason: hasResult ? "end_turn" : "tool_use", stop_sequence: null,
        usage: { input_tokens: 10, output_tokens: 10 } };
      if (!data.stream) { response.setHeader("content-type", "application/json"); response.end(JSON.stringify(result)); return; }
      response.setHeader("content-type", "text/event-stream");
      const emit = (type, value) => response.write(`event: ${type}\ndata: ${JSON.stringify({ type, ...value })}\n\n`);
      emit("message_start", { message: { ...result, content: [], stop_reason: null } });
      for (const [index, block] of content.entries()) {
        emit("content_block_start", { index, content_block: block.type === "tool_use" ? { ...block, input: {} } : { type: "text", text: "" } });
        emit("content_block_delta", { index, delta: block.type === "tool_use"
          ? { type: "input_json_delta", partial_json: JSON.stringify(block.input) } : { type: "text_delta", text: block.text } });
        emit("content_block_stop", { index });
      }
      emit("message_delta", { delta: { stop_reason: result.stop_reason, stop_sequence: null }, usage: { output_tokens: 10 } });
      emit("message_stop", {});
      response.end();
    });
    const native = socketServer(socket => {
      sockets.add(socket); socket.on("close", () => sockets.delete(socket)); socket.on("error", () => {});
      let buffer = "";
      socket.on("data", chunk => {
        buffer += chunk;
        let end;
        while ((end = buffer.indexOf("\n")) >= 0) {
          const frame = JSON.parse(buffer.slice(0, end)); buffer = buffer.slice(end + 1);
          nativeFrames.push(frame);
          if (frame.type === "hello") {
            daemonPIDs.add(frame.pid);
            socket.write(JSON.stringify({ type: "welcome", sessionID: frame.sessionID }) + "\n");
          } else if (frame.type === "request") {
            socket.write(JSON.stringify({ type: "reply", sessionID: frame.sessionID, requestID: frame.request.id,
              ...(question ? { decision: "answer", answers: { "0": ["A", "Custom choice"] } }
                : { decision: scenario, ...(scenario === "deny" ? { feedback: "Declined by isolated fixture." } : {}) }) }) + "\n");
          }
        }
      });
    });
    api.listen(0, "127.0.0.1"); native.listen(0, "127.0.0.1");
    await Promise.all([once(api, "listening"), once(native, "listening")]);
    let child;
    t.after(async () => {
      if (child && child.exitCode === null && child.signalCode === null) {
        const exited = once(child, "exit");
        child.kill("SIGTERM");
        await Promise.race([exited, sleep(2000, undefined, { ref: false })]);
        if (child.exitCode === null && child.signalCode === null) { child.kill("SIGKILL"); await exited; }
      }
      for (const pid of daemonPIDs) { try { process.kill(pid, "SIGTERM"); } catch {} }
      for (const socket of sockets) socket.destroy();
      api.closeAllConnections();
      await Promise.all([new Promise(r => api.close(r)), new Promise(r => native.close(r))]);
      await sleep(100);
      await rm(root, { recursive: true, force: true });
    });
    await writeFile(join(notify, "connection.json"), JSON.stringify({ port: native.address().port, token: "fixture-only" }), { mode: 0o600 });
    const settingsPath = await setupClaude(config);
    const settings = JSON.parse(await readFile(settingsPath, "utf8"));
    const observer = join(root, "observer.cjs"), journal = join(root, "events.jsonl");
    await writeFile(observer, `let raw="";process.stdin.on("data",d=>raw+=d);process.stdin.on("end",()=>require("node:fs").appendFileSync(${JSON.stringify(journal)},raw+"\\n"));`);
    const quote = value => "'" + value.replace(/'/g, "'\\''") + "'";
    for (const groups of Object.values(settings.hooks)) groups.push({ hooks: [
      { type: "command", command: `exec ${quote(process.execPath)} ${quote(observer)}` }
    ] });
    await writeFile(settingsPath, JSON.stringify(settings));
    const profile = '(version 1)(allow default)(deny network*)' +
      '(allow network* (local ip "localhost:*") (remote ip "localhost:*") (local unix-socket) (remote unix-socket))' +
      '(deny mach-lookup (global-name "com.apple.securityd"))';
    const environment = { HOME: home, CLAUDE_CONFIG_DIR: config, PATH: process.env.PATH, TMPDIR: root,
        ANTHROPIC_API_KEY: "fixture-not-a-real-key", ANTHROPIC_BASE_URL: `http://127.0.0.1:${api.address().port}`,
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1", DISABLE_AUTOUPDATER: "1", DISABLE_TELEMETRY: "1",
        DISABLE_ERROR_REPORTING: "1", CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY: "1" };
    let stdout = "", stderr = "";
    if (scenario === "headless-question") {
      child = spawn("/usr/bin/sandbox-exec", ["-p", profile, executable, "-p", "Run the synthetic fixture tool.",
        "--model", "claude-sonnet-4-6", "--output-format", "stream-json", "--verbose", "--no-session-persistence",
        "--permission-mode", "default", "--setting-sources", "user", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
        "--disable-slash-commands", "--system-prompt", "Local fixture only.", "--tools", "AskUserQuestion"],
        { cwd: root, env: environment, stdio: ["ignore", "pipe", "pipe"] });
      child.stdout.on("data", chunk => { stdout += chunk; });
      child.stderr.on("data", chunk => { stderr += chunk; });
      assert.equal((await once(child, "exit"))[0], 0, stderr);
    } else {
      const stream = query({ prompt: "Run the synthetic fixture tool.", options: {
        cwd: root, pathToClaudeCodeExecutable: executable, env: environment, settingSources: ["user"],
        tools: [question ? "AskUserQuestion" : "Bash"], model: "claude-sonnet-4-6",
        systemPrompt: "Local fixture only.", permissionMode: "default", persistSession: false,
        extraArgs: { "strict-mcp-config": null, "disable-slash-commands": null },
        canUseTool: () => new Promise(() => {}),
        spawnClaudeCodeProcess(options) {
          child = spawn("/usr/bin/sandbox-exec", ["-p", profile, options.command, ...options.args],
            { cwd: root, env: environment, stdio: ["pipe", "pipe", "pipe"] });
          child.stderr.on("data", chunk => { stderr += chunk; });
          return child;
        }
      } });
      try {
        for await (const message of stream) stdout += JSON.stringify(message) + "\n";
      } finally { stream.close(); }
    }
    const messages = stdout.trim().split("\n").map(line => JSON.parse(line));
    assert.equal(messages.find(message => message.type === "system" && message.subtype === "init")?.claude_code_version, "2.1.81");
    const events = (await readFile(journal, "utf8")).trim().split("\n").filter(Boolean).map(line => JSON.parse(line));
    const permission = events.find(event => event.hook_event_name === "PermissionRequest");
    if (scenario === "headless-question") {
      assert.equal(permission, undefined, "plain -p has no interactive permission channel in 2.1.81");
      assert.equal(nativeFrames.some(frame => frame.type === "request"), false);
      assert.match(stdout, /Answer questions/);
      return;
    }
    assert.ok(permission, `No PermissionRequest emitted. Events: ${events.map(e => e.hook_event_name)}; output: ${stdout}`);
    assert.equal(permission.tool_name, scenario === "question" ? "AskUserQuestion" : "Bash");
    assert.ok(nativeFrames.some(frame => frame.type === "request"), "The production hook must reach Notify transport.");
    const resultRequest = apiRequests.find(data => data.messages.some(message => Array.isArray(message.content) &&
      message.content.some(block => block.type === "tool_result")));
    assert.ok(resultRequest, "The actual runtime must return the tool result to the local provider.");
    const wireResult = JSON.stringify(resultRequest.messages);
    if (question) {
      assert.match(wireResult, /Custom choice/);
      assert.match(wireResult, /A/);
    } else if (scenario === "allow") await access(join(root, "allow-marker"));
    else {
      await assert.rejects(access(join(root, "deny-marker")));
      assert.match(wireResult, /Declined by isolated fixture/);
    }
  });
