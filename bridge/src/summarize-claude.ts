import { open, constants } from "node:fs/promises";
import { query } from "@anthropic-ai/claude-agent-sdk";
import { executable } from "./executable.ts";
import { object } from "./protocol.ts";

const TIMEOUT_MS = 60_000;
const MAX_EXCERPT = 12_000;
const WINDOW = 512 * 1024;

async function readClaudeExcerpt(path: string): Promise<string> {
  const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const info = await file.stat();
    if (!info.isFile()) throw new Error("Session transcript must be a regular file.");
    async function read(start: number, length: number) {
      const buf = Buffer.alloc(length);
      const { bytesRead } = await file.read(buf, 0, length, start);
      return buf.subarray(0, bytesRead).toString("utf8");
    }
    const first = await read(0, Math.min(info.size, WINDOW));
    const chunks = [first];
    if (info.size > WINDOW) {
      chunks[0] = first.slice(0, Math.max(0, first.lastIndexOf("\n")));
      const start = Math.max(WINDOW, info.size - WINDOW);
      const tail = await read(start - 1, Math.min(WINDOW, info.size - start) + 1);
      const boundary = tail.indexOf("\n");
      chunks.push(boundary < 0 ? "" : tail.slice(boundary + 1));
    }
    const messages: string[] = [];
    let firstUser = "";
    for (const chunk of chunks) {
      for (const [index, line] of chunk.split("\n").entries()) {
        if (!line.trim()) continue;
        let entry: unknown;
        try { entry = JSON.parse(line); } catch {
          if (index === chunk.split("\n").length - 1 && !chunk.endsWith("\n")) continue;
          throw new Error("Could not parse transcript line.");
        }
        if (!object(entry)) continue;
        const type = String(entry.type ?? "");
        if (!["human", "assistant"].includes(type)) continue;
        // Extract text from message.content (array) or message.content (string).
        const msg = entry.message;
        if (!object(msg)) continue;
        let text = "";
        if (typeof msg.content === "string") {
          text = msg.content;
        } else if (Array.isArray(msg.content)) {
          text = msg.content
            .filter((b: unknown) => object(b) && b.type === "text" && typeof b.text === "string")
            .map((b: unknown) => (b as { text: string }).text)
            .join("\n");
        }
        if (!text.trim()) continue;
        const label = type === "human" ? "User" : "Assistant";
        const formatted = `${label}: ${text}`;
        if (!firstUser && type === "human") firstUser = formatted.slice(0, 2000);
        messages.push(formatted.slice(0, 10000));
      }
    }
    if (!messages.length) throw new Error("This session has no saved conversation text to summarize yet.");
    return (firstUser + "\n\n" + messages.join("\n\n").slice(-9998)).slice(0, MAX_EXCERPT);
  } finally { await file.close(); }
}

async function main(): Promise<void> {
  const transcriptPath = process.argv[2];
  if (!transcriptPath || process.argv.length !== 3) {
    throw new Error("A Claude session transcript path is required.");
  }
  const excerpt = await readClaudeExcerpt(transcriptPath);
  if (!excerpt.trim() || excerpt.length > MAX_EXCERPT) throw new Error("Invalid summary excerpt.");

  const claudeExec = await executable("claude");
  let result: string | undefined;
  let modelUsed: string | undefined;
  let cancelled = false;
  const timer = setTimeout(() => { cancelled = true; }, TIMEOUT_MS);

  try {
    const stream = query({
      prompt: "Summarize this conversation excerpt:\n\n" + excerpt,
      options: {
        cwd: process.cwd(),
        pathToClaudeCodeExecutable: claudeExec,
        settingSources: ["user"],
        model: "claude-haiku-4-5-20251001",
        permissionMode: "bypassPermissions",
        systemPrompt: "Write a concise plain-text summary of at most 250 words and 6000 characters in complete sentences. " +
                "Cover the goal, progress, decisions and remaining work. Use short paragraphs. " +
                "Do not pretend the excerpt is the entire conversation. " +
                "Return only the description, no JSON, markdown or preamble."
      }
    });
    for await (const message of stream) {
      if (cancelled) { stream.close(); break; }
      if ("session_id" in message) modelUsed = "claude-haiku-4-5-20251001";
      if (message.type === "assistant") {
        for (const block of message.message.content) {
          if (block.type === "text") result = (result ?? "") + block.text;
        }
      }
      if (message.type === "result" && message.is_error) {
        throw new Error("errors" in message ? message.errors.join("\n") : message.result);
      }
    }
  } finally { clearTimeout(timer); }

  if (cancelled) throw new Error("Summary timed out after 60 seconds.");
  const text = result?.trim();
  if (!text) throw new Error("The summary model returned an empty description.");
  if (/^[{[]|^```/.test(text)) throw new Error("The summary model returned structured data.");
  if (text.split(/\s+/u).length > 250 || text.length > 6000) {
    throw new Error("The summary exceeded 250 words or 6000 characters.");
  }
  process.stdout.write(JSON.stringify({ text, model: modelUsed ?? "claude-haiku" }) + "\n");
}

main().catch(err => {
  console.error(err instanceof Error ? err.message : String(err));
  process.exitCode = 1;
});
