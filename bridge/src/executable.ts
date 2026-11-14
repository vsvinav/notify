import { access } from "node:fs/promises";
import { constants } from "node:fs";
import { delimiter, join } from "node:path";

export async function executable(name: string): Promise<string> {
  for (const directory of (process.env.PATH ?? "").split(delimiter)) {
    if (!directory) continue;
    const path = join(directory, name);
    try { await access(path, constants.X_OK); return path; }
    catch (error) {
      if (!(error instanceof Error && "code" in error && ["ENOENT", "EACCES", "ENOTDIR"].includes(String(error.code)))) throw error;
    }
  }
  throw new Error(`${name} is not installed on PATH. Install and sign in to it first.`);
}
