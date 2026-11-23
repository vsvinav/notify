import { createInterface } from "node:readline";
import { appendFileSync, mkdirSync, readFileSync, existsSync, unlinkSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { createConnection } from "node:net";

let directory, agent, remembered;
process.on("SIGTERM", async () => {
  await remembered?.close();
  if (directory && existsSync(join(directory, "delay-stop"))) {
    setTimeout(() => process.exit(0), 300);
  } else process.exit(0);
});
const emit = value => process.stdout.write(JSON.stringify(value) + "\n");
for await (const line of createInterface({ input: process.stdin })) {
  const command = JSON.parse(line);
  if (command.type === "start") {
    directory = command.directory;
    mkdirSync(directory, { recursive: true, mode: 0o700 });
  }
  appendFileSync(join(directory, "events.jsonl"), JSON.stringify(command) + "\n", { mode: 0o600 });
  if (command.type === "start" && existsSync(join(directory, "remembered-fixture.json"))) {
    const config = JSON.parse(readFileSync(join(directory, "remembered-fixture.json"), "utf8"));
    const { startRememberedFixture } = await import("./remembered-authority.mjs");
    remembered = await startRememberedFixture({ ...config, directory, origin: command.origin, emit });
    continue;
  }
  if (remembered) {
    await remembered.command(command);
    continue;
  }
  if (command.type === "start") {
    if (process.env.NODE_TLS_REJECT_UNAUTHORIZED !== "1") throw new Error("TLS verification required");
    if (basename(process.argv[1]) === "remote-main.mjs") {
      emit({ type: "status", status: { state: "connecting", url: command.origin, devices: [], pendingPairingIDs: [] } });
    } else {
      emit({ type: "status", status: {
        url: "https://fixture.local:9443", setupURL: "http://fixture.local:9444",
        fingerprint: "fixture", devices: [], pendingPairingIDs: []
      } });
      const connection = JSON.parse(readFileSync(join(dirname(directory), "connection.json"), "utf8"));
      agent = createConnection({ host: "127.0.0.1", port: connection.port }, () =>
        agent.write(JSON.stringify({ type: "hello", sessionID: "fixture", token: connection.token,
          agent: "copilot", cwd: "/fixture" }) + "\n"));
      let buffer = "";
      agent.on("data", data => {
        buffer += data;
        let end;
        while ((end = buffer.indexOf("\n")) !== -1) {
          const packet = JSON.parse(buffer.slice(0, end));
          buffer = buffer.slice(end + 1);
          appendFileSync(join(directory, "agent.jsonl"), JSON.stringify(packet) + "\n", { mode: 0o600 });
        }
      });
    }
  } else if (command.type === "invite") {
    const path = join(directory, "inbox.json");
    if (existsSync(path)) {
      const events = JSON.parse(readFileSync(path, "utf8"));
      unlinkSync(path);
      for (const event of events) emit(event);
    }
  }
}
agent?.destroy();
await remembered?.close();
