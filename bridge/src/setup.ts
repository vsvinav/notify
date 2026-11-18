import { mkdir, readFile, writeFile, lstat, open, rename, unlink } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { object } from "./protocol.ts";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";

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

export async function setupClaude(configDir = process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude")): Promise<string> {
  const settingsPath = join(configDir, "settings.json");
  const script = fileURLToPath(new URL("./claude-hook.js", import.meta.url));
  const quote = (text: string) => "'" + text.replace(/'/g, "'\\''") + "'";
  // exec leaves the hook's parent as Claude, rather than an ephemeral command shell.
  const hookCommand = `exec ${quote(process.execPath)} ${quote(script)}`;
  const legacyCommand = `${JSON.stringify(process.execPath)} ${JSON.stringify(script)}`;
  const events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
    "PostToolUseFailure", "PermissionRequest", "Stop", "SubagentStart", "SubagentStop", "SessionEnd"];
  await mkdir(configDir, { recursive: true, mode: 0o700 });
  const directory = await lstat(configDir);
  if (!directory.isDirectory() || directory.uid !== process.getuid?.()) throw new Error("Claude settings directory must be an owned regular directory.");
  const lockPath = join(configDir, ".notify-setup.lock");
  const lock = await open(lockPath, "wx", 0o600);
  const replacement = join(configDir, `.settings.notify-${randomUUID()}.json`);
  async function readSettings(): Promise<string | undefined> {
    try {
      const info = await lstat(settingsPath);
      if (!info.isFile() || info.uid !== process.getuid?.()) throw new Error("Claude settings must be an owned regular file, not a symlink.");
      return await readFile(settingsPath, "utf8");
    } catch (error) {
      if (object(error) && error.code === "ENOENT") return undefined;
      throw error;
    }
  }
  try {
    const original = await readSettings();
    const settings: unknown = original === undefined ? {} : JSON.parse(original);
    if (!object(settings) || (settings.hooks !== undefined && !object(settings.hooks))) {
      throw new Error("Claude settings and hooks must be JSON objects.");
    }
    const hooks = (settings.hooks ?? {}) as Record<string, unknown>;
    for (const event of events) {
      if (hooks[event] !== undefined && !Array.isArray(hooks[event])) throw new Error(`Invalid Claude hook groups for ${event}.`);
      const existing = (hooks[event] ?? []) as unknown[];
      let present = false;
      for (const group of existing) {
        if (!object(group) || !Array.isArray(group.hooks)) throw new Error(`Invalid Claude hook group for ${event}.`);
        for (const handler of group.hooks) {
          if (object(handler) && handler.type === "command" && [hookCommand, legacyCommand].includes(String(handler.command))) {
            handler.command = hookCommand;
            handler.timeout = event === "PermissionRequest" ? 120 : 10;
            present = true;
          }
        }
      }
      if (!present) existing.push({ hooks: [{ type: "command", command: hookCommand, timeout: event === "PermissionRequest" ? 120 : 10 }] });
      hooks[event] = existing;
    }
    settings.hooks = hooks;
    await writeFile(replacement, JSON.stringify(settings, null, 2) + "\n", { flag: "wx", mode: 0o600 });
    if (await readSettings() !== original) throw new Error("Claude settings changed during setup; retry without concurrent edits.");
    await rename(replacement, settingsPath);
    return settingsPath;
  } finally {
    await unlink(replacement).catch(() => {});
    await lock.close();
    await unlink(lockPath);
  }
}
