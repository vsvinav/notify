import { mkdtemp, rm, lstat } from "node:fs/promises";
import { join } from "node:path";
import { homedir, tmpdir } from "node:os";
import type { CopilotClient } from "@github/copilot-sdk";
import { executable } from "./executable.ts";
import { createSummaryClient, generateDescription, readExcerpt } from "./summary.ts";

let client: CopilotClient | undefined;
let directory: string | undefined;
let cleaning: Promise<void> | undefined;
function cleanup(): Promise<void> {
  return cleaning ??= (async () => {
    if (client) await client.forceStop();
    if (directory) await rm(directory, { recursive: true, force: true });
  })();
}
for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.once(signal, () => {
    void cleanup().then(() => process.exit(1), error => { console.error(String(error)); process.exit(1); });
  });
}

try {
  const id = process.argv[2];
  if (!id || process.argv.length !== 3 || !/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(id)) {
    throw new Error("A valid Copilot session ID is required.");
  }
  const home = process.env.COPILOT_HOME ?? join(homedir(), ".copilot");
  const sessionDirectory = join(home, "session-state", id);
  const info = await lstat(sessionDirectory);
  if (!info.isDirectory() || info.isSymbolicLink()) throw new Error("Invalid session directory.");
  const excerpt = await readExcerpt(join(sessionDirectory, "events.jsonl"));
  directory = await mkdtemp(join(tmpdir(), "notify-summary-"));
  client = createSummaryClient(await executable("copilot"), home, directory);
  const result = await generateDescription(client, excerpt, directory);
  await cleanup();
  process.stdout.write(JSON.stringify(result) + "\n");
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  try { await cleanup(); } catch (cleanupError) { console.error(`Summary cleanup failed: ${String(cleanupError)}`); }
  process.exitCode = 1;
}
