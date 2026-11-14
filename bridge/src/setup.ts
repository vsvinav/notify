import { mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

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
