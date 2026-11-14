import { joinSession } from "@github/copilot-sdk/extension";
import { Bridge } from "./connection.ts";
import { attachCopilot } from "./attachment.ts";
import { attachSteering } from "./steering.ts";
import { ActivityFeed } from "./activity.ts";

const session = await joinSession({
  // Opt into permission events after Copilot's explicit extension-access consent.
  onPermissionRequest: () => ({ kind: "no-result" })
});
const bridge = new Bridge("copilot", process.cwd(), undefined, session.sessionId, false);
const attachment = attachCopilot(session, bridge);
const steering = attachSteering(session, bridge);
const activity = new ActivityFeed(entry => bridge.activity(entry));
const unsubscribeActivity = session.on(event => activity.receive(event));
bridge.enableActivity();
await bridge.start();
bridge.setState("ready", "Connected to the original Copilot terminal");
try { await attachment.recover(); }
catch (error) { bridge.error(`Could not recover pending approvals; check Copilot: ${String(error)}`); }

function stop() {
  unsubscribeActivity();
  activity.stop();
  steering.stop();
  attachment.stop();
  bridge.stop();
  process.exit(0);
}
process.once("SIGTERM", stop);
process.once("SIGINT", stop);
process.once("disconnect", stop);
