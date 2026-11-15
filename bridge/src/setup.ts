import { mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { object } from "./protocol.ts";

export async function setupCopilot(home = process.env.COPILOT_HOME ?? join(homedir(), ".copilot")) {
  const directory = join(home, "extensions", "notify");
  const path = join(directory, "extension.mjs");
  const source = `// Notify's local live-session bridge.\nawait import(${JSON.stringify(new URL("./copilot-extension.js", import.meta.url).href)});\n`;
  await mkdir(directory, { recursive: true, mode: 0o700 });
  try { await writeFile(path, source, { flag: "wx", mode: 0o600 }); }
  catch (error) {
    if (!(error instanceof Error && "code" in error && error.code === "EEXIST")) throw error;
    if (await readFile(path, "utf8") !== source) throw new Error(`Not replacing an existing extension: ${path}`);
  }
  return path;
}

export async function setupClaude(): Promise<string> {
  const { readFile: readFile2, writeFile: writeFile2, mkdir: mkdir2, stat, chmod } = await import("node:fs/promises");
  const { join: join2, dirname } = await import("node:path");
  const { homedir: homedir2 } = await import("node:os");
  const { fileURLToPath } = await import("node:url");
  // The hook script lives next to this built cli.js.
  const scriptDir = dirname(fileURLToPath(import.meta.url));
  const hookScript = join2(scriptDir, "claude-hook.js");
  const configDir = process.env.CLAUDE_CONFIG_DIR ?? join2(homedir2(), ".claude");
  const settingsPath = join2(configDir, "settings.json");
  // Find node executable.
  const nodePath = process.execPath;
  const hookCommand = `${JSON.stringify(nodePath)} ${JSON.stringify(hookScript)}`;
  // Load or init settings.
  let settings: Record<string, unknown> = {};
  try {
    const info = await stat(settingsPath);
    if ((info.mode & 0o077) !== 0) throw new Error("settings.json has insecure permissions. Fix with: chmod 600 " + settingsPath);
    const raw = await readFile2(settingsPath, "utf8");
    settings = JSON.parse(raw);
  } catch (err: unknown) {
    if (object(err) && err.code !== "ENOENT") throw err;
    await mkdir2(configDir, { recursive: true });
  }
  const events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
    "PermissionRequest", "Stop", "SubagentStart", "SubagentStop", "SessionEnd"];
  const hooks = (settings.hooks as Record<string, unknown[]> | undefined) ?? {};
  const entry = { hooks: [{ type: "command", command: hookCommand }] };
  for (const event of events) {
    const existing = Array.isArray(hooks[event]) ? (hooks[event] as unknown[]) : [];
    const present = existing.some(g => object(g) &&
      Array.isArray(g.hooks) && g.hooks.some((h: unknown) => object(h) && h.command === hookCommand));
    if (!present) existing.push(entry);
    hooks[event] = existing;
  }
  settings.hooks = hooks;
  await writeFile2(settingsPath, JSON.stringify(settings, null, 2) + "\n", { mode: 0o600 });
  await chmod(settingsPath, 0o600);
  return settingsPath;
}
