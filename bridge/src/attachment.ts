import type { CopilotSession, SessionEvent } from "@github/copilot-sdk";
import { Bridge } from "./connection.ts";
import { formContent, formQuestions, object, safeRead, validateReply, type Reply, type Request } from "./protocol.ts";
import { scopedOptions, selectedPermissionOption, type ScopedOption } from "./permission-options.ts";

type Submission = { request: Request; respond: (reply: Reply) => Promise<{ success: boolean }> };
type Waiting = { submission?: Submission; sending: boolean; completed: boolean };
const detail = (value: unknown) => JSON.stringify(value, null, 2).slice(0, 120_000);

export function attachCopilot(session: CopilotSession, bridge: Bridge) {
  const waiting = new Map<string, Waiting>();
  const completedDuringRecovery = new Set<string>();
  let recovering = true;
  let stopped = false;
  let responding = false;

  function cancel(id: string) {
    waiting.delete(id);
    bridge.pending.cancel(id);
  }
  async function offer(id: string, build: () => Promise<Submission>) {
    if (stopped || waiting.has(id) || completedDuringRecovery.has(id)) return;
    if (waiting.size >= 100) throw new Error("Too many pending requests; answer additional prompts in Copilot.");
    const entry: Waiting = { sending: false, completed: false };
    waiting.set(id, entry);
    try {
      const submission = await build();
      if (stopped || waiting.get(id) !== entry) return;
      entry.submission = submission;
      bridge.offer(submission.request);
    } catch (error) {
      cancel(id);
      throw error;
    }
  }
  bridge.onReply = async value => {
    if (!object(value) || typeof value.requestID !== "string") return false;
    const id = value.requestID, entry = waiting.get(id);
    if (!entry?.submission || entry.sending || !validateReply(entry.submission.request, value)) return false;
    if (value.automatic && !(value.approvalScope === "session"
      ? entry.submission.request.sessionAutoEligible : entry.submission.request.autoEligible)) return false;
    entry.sending = true;
    try {
      const result = await entry.submission.respond(value);
      if (waiting.get(id) !== entry) return false;
      if (result.success) {
        waiting.delete(id);
        bridge.pending.reply(value);
      } else {
        cancel(id);
        bridge.error("Copilot already resolved this request. No additional reply was applied.");
      }
      return true;
    } catch (error) {
      if (entry.completed) cancel(id);
      throw error;
    } finally { entry.sending = false; }
  };

  async function eligibility(event: Extract<SessionEvent, { type: "permission.requested" }>) {
    const request = event.data.permissionRequest;
    const manual = { safe: false, session: false };
    if (!["read", "write", "shell", "mcp", "custom-tool"].includes(request.kind) ||
        request.managedApprovalRequired || ("requestSandboxBypass" in request && request.requestSandboxBypass)) return manual;
    const policy = await session.rpc.managedSettings.getCurrentSnapshot();
    if (!policy || policy.source !== "none" || policy.failClosed || policy.managedKeys.length) return manual;
    return { safe: request.kind === "read" && await safeRead(bridge.cwd, "Read", { file_path: request.path }), session: true };
  }
  async function permissionResponse(id: string, reply: Reply, options: ScopedOption[] = []) {
    if (reply.permissionOptionID) {
      const pending = await session.rpc.permissions.pendingRequests();
      const current = pending.items.find(item => item.requestId === id);
      if (!current) return { success: false };
      const refreshed = await scopedOptions(session, current.request, bridge.cwd);
      const result = selectedPermissionOption(options, refreshed, reply);
      return session.rpc.permissions.handlePendingPermissionRequest({ requestId: id, result });
    }
    return session.rpc.permissions.handlePendingPermissionRequest({
      requestId: id, result: reply.decision === "allow"
        ? { kind: "approve-once", approvedInteractively: reply.automatic !== true }
        : { kind: "reject", feedback: reply.feedback?.trim() ?? "User declined in Notify." }
    });
  }
  async function optionsFor(prompt: Parameters<typeof scopedOptions>[1]): Promise<ScopedOption[]> {
    try { return await scopedOptions(session, prompt, bridge.cwd); }
    catch (error) {
      bridge.error(`Additional approval choices could not be verified: ${String(error)}`);
      return [];
    }
  }
  async function receive(event: SessionEvent) {
    if (stopped) return;
    if (event.type === "session.title_changed") {
      bridge.setTitle(event.data.title);
    } else if (["permission.completed", "elicitation.completed", "user_input.completed", "exit_plan_mode.completed"].includes(event.type) &&
        "requestId" in event.data && typeof event.data.requestId === "string") {
      const id = event.data.requestId;
      if (recovering) completedDuringRecovery.add(id);
      const entry = waiting.get(id);
      if (entry) {
        entry.completed = true;
        // The runtime's acceptance result distinguishes our reply from a competing terminal reply.
        if (!entry.sending) cancel(id);
      }
    } else if (event.type === "permission.requested") {
      if (event.data.resolvedByHook) return;
      await offer(event.data.requestId, async () => {
        let eligible = { safe: false, session: false };
        try { eligible = await eligibility(event); }
        catch (error) { bridge.error(`Auto-yes unavailable; this request requires manual approval: ${String(error)}`); }
        const options = await optionsFor(event.data.promptRequest);
        return {
          request: { id: event.data.requestId, kind: "permission", title: `Allow ${event.data.permissionRequest.kind}?`,
            detail: detail(event.data.promptRequest ?? event.data.permissionRequest), questions: [],
            autoEligible: eligible.safe, sessionAutoEligible: eligible.session, supportsFeedback: true,
            permissionOptions: options.map(({ result, ...option }) => option) },
          respond: async reply => {
            if (reply.automatic) {
              const current = await eligibility(event);
              if (!(reply.approvalScope === "session" ? current.session : current.safe)) {
                throw new Error("Permission policy changed. Review this request manually.");
              }
            }
            return permissionResponse(event.data.requestId, reply, options);
          }
        };
      });
    } else if (event.type === "elicitation.requested") {
      const data = event.data;
      const agentInitiated = data.elicitationSource === undefined;
      await offer(data.requestId, async () => {
        const questions = data.mode === "url" ? [] : formQuestions(data.requestedSchema, agentInitiated);
        return {
          request: { id: data.requestId, kind: questions.length ? "question" : "permission", title: data.message,
            detail: data.mode === "url" ? `Complete this browser action yourself before approving:\n${data.url ?? "No URL supplied"}` : detail(data.requestedSchema),
            autoEligible: false, questions },
          respond: reply => session.rpc.ui.handlePendingElicitation({
            requestId: data.requestId, result: reply.decision === "deny" ? { action: "decline" } :
              { action: "accept", ...(data.mode === "url" ? {} : { content: formContent(data.requestedSchema, reply.answers ?? {}, agentInitiated) }) }
          })
        };
      });
    } else if (event.type === "user_input.requested") {
      const data = event.data;
      await offer(data.requestId, async () => ({
        request: { id: data.requestId, kind: "question", title: data.question, detail: "", autoEligible: false,
          questions: [{ id: "0", text: data.question, multiple: false, allowFreeform: data.allowFreeform !== false,
            options: (data.choices ?? []).map(label => ({ label, description: "" })) }] },
        respond: reply => {
          const answer = reply.decision === "deny" ? "User declined to answer." : reply.answers!["0"][0];
          return session.rpc.ui.handlePendingUserInput({ requestId: data.requestId,
            response: { answer, wasFreeform: !data.choices?.includes(answer) } });
        }
      }));
    } else if (event.type === "exit_plan_mode.requested") {
      const data = event.data;
      await offer(data.requestId, async () => ({
        request: { id: data.requestId, kind: "question", title: "Review the plan", detail: data.planContent,
          autoEligible: false, questions: [{ id: "0", text: data.summary, multiple: false, allowFreeform: false,
            options: data.actions.map(label => ({ label, description: "" })) }] },
        respond: reply => session.rpc.ui.handlePendingExitPlanMode({ requestId: data.requestId,
          response: { approved: reply.decision === "answer", selectedAction: data.actions.find(action => action === reply.answers?.["0"]?.[0]) } })
      }));
    } else if (event.type === "assistant.message_delta") {
      if (!event.agentId && !responding) { responding = true; bridge.setState("working", "Copilot is responding"); }
      bridge.output(event.data.deltaContent);
    } else if (event.type === "tool.execution_start") {
      responding = false;
      bridge.setState("working", `Using ${event.data.toolName}`);
    } else if (event.type === "assistant.turn_start") {
      responding = false;
      bridge.setState("working", "Copilot is working");
    } else if (event.type === "session.idle") {
      responding = false;
      bridge.setState("ready", "Connected to the original Copilot terminal");
    }
    else if (event.type === "session.error") bridge.error(event.data.message);
    else if (event.type === "session.shutdown") { stop(); bridge.stop(); }
  }
  const unsubscribe = session.on(event => { void receive(event).catch(error => bridge.error(error)); });
  function stop() {
    stopped = true;
    unsubscribe();
    for (const id of waiting.keys()) cancel(id);
    completedDuringRecovery.clear();
  }
  return {
    stop,
    async recover() {
      try {
        const pending = await session.rpc.permissions.pendingRequests();
        for (const item of pending.items) {
          await offer(item.requestId, async () => {
            const options = await optionsFor(item.request);
            return {
            request: { id: item.requestId, kind: "permission", title: "Copilot needs approval",
              detail: detail(item.request), questions: [], autoEligible: false, supportsFeedback: true,
              permissionOptions: options.map(({ result, ...option }) => option) },
            respond: reply => permissionResponse(item.requestId, reply, options)
          }; });
        }
      } finally { recovering = false; completedDuringRecovery.clear(); }
    }
  };
}
