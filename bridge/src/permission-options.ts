import type { PermissionRequestedData, CopilotSession } from "@github/copilot-sdk";
import type { PermissionUpdate } from "@anthropic-ai/claude-agent-sdk";
import type { PermissionOption, Reply } from "./protocol.ts";

type Prompt = NonNullable<PermissionRequestedData["promptRequest"]>;
type Decision = Parameters<CopilotSession["rpc"]["permissions"]["handlePendingPermissionRequest"]>[0]["result"];
type Approval = Extract<Decision, { kind: "approve-for-location" }>["approval"];
export type ScopedOption = PermissionOption & { result: Decision };

export function permissionOptions(prompt: Prompt, locationKey?: string): ScopedOption[] {
  if (("managedApprovalRequired" in prompt && prompt.managedApprovalRequired) ||
      ("requestSandboxBypass" in prompt && prompt.requestSandboxBypass)) return [];
  const options: ScopedOption[] = [];
  function tool(approval: Approval, scope: string, suffix = "", persist = true) {
    options.push({ id: "session" + suffix, label: `Allow every time in this session${suffix ? " (server)" : ""}`,
      detail: `Remember ${scope} for this running Copilot session. Copilot may ask again after resume. This is not Notify Auto-yes.`,
      result: { kind: "approve-for-session", approval } });
    if (locationKey && persist) options.push({ id: "project" + suffix, label: `Always allow in this project${suffix ? " (server)" : ""}`,
      detail: `Persist ${scope} for ${locationKey}. Applies to future sessions in that location until removed in Copilot.`,
      result: { kind: "approve-for-location", approval, locationKey } });
  }
  switch (prompt.kind) {
    case "commands":
      if (prompt.canOfferSessionApproval && prompt.commandIdentifiers.length) {
        tool({ kind: "commands", commandIdentifiers: [...prompt.commandIdentifiers] }, `command patterns: ${prompt.commandIdentifiers.join(", ")}`);
      }
      break;
    case "write":
      if (prompt.canOfferSessionApproval) tool({ kind: "write" }, "file writes (not only this file)");
      break;
    case "read": tool({ kind: "read" }, "file reads (not only this file); separate path restrictions still apply"); break;
    case "mcp":
      tool({ kind: "mcp", serverName: prompt.serverName, toolName: prompt.toolName }, `tool ${prompt.serverName}/${prompt.toolName}`);
      if (prompt.canOfferServerWideApproval !== false) {
        tool({ kind: "mcp", serverName: prompt.serverName, toolName: null }, `ALL tools from MCP server ${prompt.serverName}`, "-server");
      }
      break;
    case "custom-tool": tool({ kind: "custom-tool", toolName: prompt.toolName }, `tool ${prompt.toolName}`); break;
    case "memory": tool({ kind: "memory" }, "memory writes"); break;
    case "extension-management": tool({ kind: "extension-management", operation: prompt.operation }, `extension operation ${prompt.operation}`); break;
    case "workflow": tool({ kind: "workflow", approvalKey: prompt.approvalKey }, `workflow ${prompt.name}`, "", prompt.canPersistApproval); break;
    case "extension-permission-access":
    case "extension-env-access":
      // Initial extension authority remains in its original terminal.
      break;
    case "path": {
      if (prompt.paths.length) options.push({ id: "session-paths", label: "Allow these paths in this session",
        detail: `Exact paths requested for ${prompt.accessKind}: ${JSON.stringify(prompt.paths)}. This path grant is not read-only; separate tool permissions still apply. No recursive directory grant. Applies to this running session; Copilot may ask again after resume.`,
        result: { kind: "approve-for-session" } });
      if (prompt.accessKind === "read" && prompt.readOnlyDirectories?.length) {
        const [first, ...rest] = prompt.readOnlyDirectories;
        options.push({ id: "read-directories", label: "Allow read-only access in this session",
          detail: `Read-only directory access: ${prompt.readOnlyDirectories.join(", ")}. Retained for this logical session, including resume.`,
          result: { kind: "approve-read-only-for-session", directories: [first, ...rest] } });
      }
      break;
    }
    case "url": {
      const url = new URL(prompt.url);
      if (!["https:", "http:"].includes(url.protocol)) return [];
      const origin = url.origin;
      options.push({ id: "origin", label: "Allow this site in this session",
        detail: `Allow ${origin} for this logical session.`, result: { kind: "approve-for-session", domain: origin } });
      if (prompt.parentDomainPattern) options.push({ id: "parent-domain", label: "Allow this domain and subdomains in this session",
        detail: `Session-only scope supplied by Copilot: ${prompt.parentDomainPattern}.`,
        result: { kind: "approve-for-session", domain: prompt.parentDomainPattern } });
      options.push({ id: "permanent-origin", label: "Always allow this site",
        detail: `Persist access to ${origin} across sessions until removed in Copilot.`,
        result: { kind: "approve-permanently", domain: origin } });
      break;
    }
  }
  return options.filter(option => option.detail.length <= 4000);
}

export async function scopedOptions(session: CopilotSession, prompt: Prompt | undefined, cwd: string): Promise<ScopedOption[]> {
  if (!prompt || !permissionOptions(prompt).length) return [];
  const policy = await session.rpc.managedSettings.getCurrentSnapshot();
  if (!policy || policy.source !== "none" || policy.failClosed || policy.managedKeys.length) return [];
  const location = await session.rpc.permissions.locations.resolve({ workingDirectory: cwd });
  if (!location.locationKey.startsWith("/")) throw new Error("Copilot returned an invalid permission location.");
  return permissionOptions(prompt, location.locationKey);
}

export function selectedPermissionOption(offered: ScopedOption[], current: ScopedOption[], reply: Reply): Decision {
  const original = offered.find(option => option.id === reply.permissionOptionID);
  const checked = current.find(option => option.id === reply.permissionOptionID);
  if (reply.automatic || reply.decision !== "allow" || !original || !checked ||
      JSON.stringify(original) !== JSON.stringify(checked)) {
    throw new Error("Approval scope or policy changed. Review the request in Copilot before retrying.");
  }
  return checked.result;
}

export function claudePermissionOptions(suggestions: PermissionUpdate[] | undefined): PermissionOption[] {
  if (!suggestions?.length) return [];
  const destinations = {
    session: "this session", userSettings: "user settings (all projects)", projectSettings: "shared project settings",
    localSettings: "local project settings", cliArg: "this CLI invocation"
  };
  const descriptions: string[] = [];
  for (const update of suggestions) {
    if (update.type === "addRules" && update.behavior === "allow" && update.rules.length) {
      descriptions.push(`Allow ${update.rules.map(rule => rule.ruleContent === undefined ? `${rule.toolName} (all uses)` : `${rule.toolName}: ${rule.ruleContent}`).join(", ")} in ${destinations[update.destination]}.`);
    } else if (update.type === "addDirectories" && update.directories.length) {
      descriptions.push(`Add directory access: ${update.directories.join(", ")} in ${destinations[update.destination]}.`);
    } else return [];
  }
  const detail = descriptions.join("\n\n") + "\n\nApply Claude's complete suggested permission update. Saved settings may affect future sessions.";
  return detail.length <= 4000 ? [{ id: "suggested", label: "Allow every time (Claude's suggested scope)", detail }] : [];
}
