import { query, type Query } from "@anthropic-ai/claude-agent-sdk";
import { CopilotClient, RuntimeConnection, type CopilotSession, type SessionConfig } from "@github/copilot-sdk";
import { Bridge } from "./connection.ts";
import { claudeQuestions, formQuestions, formContent, safeRead, object, type Question } from "./protocol.ts";
import { ClaudeTeam } from "./claude-team.ts";
import { claudePermissionOptions, scopedOptions, selectedPermissionOption, type ScopedOption } from "./permission-options.ts";
import { attachSubagents } from "./subagents.ts";
import { ActivityFeed, boundActivityText } from "./activity.ts";

const detail = (value: unknown) => JSON.stringify(value, null, 2).slice(0, 120_000);

export async function askForm(bridge: Bridge, message: string, schema: unknown, signal?: AbortSignal, agentInitiated = false) {
  const questions = formQuestions(schema, agentInitiated);
  if (!questions.length) {
    const reply = await bridge.ask({ kind: "permission", title: message, detail: "Confirm this empty form.", autoEligible: false, questions: [] }, signal);
    return reply.decision === "allow" ? { action: "accept" as const, content: {} } : { action: "decline" as const };
  }
  let validation = "";
  while (!signal?.aborted) {
    const reply = await bridge.ask({
      kind: "question", title: message, detail: validation || "Complete the requested fields.",
      autoEligible: false, questions
    }, signal);
    if (reply.decision === "deny") return { action: "decline" as const };
    try { return { action: "accept" as const, content: formContent(schema, reply.answers ?? {}, agentInitiated) }; }
    catch (error) {
      validation = error instanceof Error ? error.message : String(error);
      console.error(`Notify: ${validation}. Please correct the answer.`);
    }
  }
  return { action: "cancel" as const };
}

async function urlConsent(bridge: Bridge, message: string, url: string | undefined, signal?: AbortSignal) {
  const response = await bridge.ask({
    kind: "permission", title: message,
    detail: `This requires action in your browser. Open the URL yourself, then approve only after completing it:\n\n${url ?? "No URL provided"}`,
    autoEligible: false, questions: []
  }, signal);
  return { action: response.decision === "allow" ? "accept" as const : "decline" as const };
}

export class ClaudeAgent {
  private resume?: string;
  private current?: Query;
  private controller?: AbortController;
  private team?: ClaudeTeam;
  constructor(private bridge: Bridge, private executable: string, private model?: string, resume?: string, private makeQuery: typeof query = query) { this.resume = resume; }
  async checkConnection(): Promise<void> {
    const stream = async function* () { await new Promise<void>(() => {}); };
    const probe = query({ prompt: stream(), options: {
      cwd: this.bridge.cwd, pathToClaudeCodeExecutable: this.executable,
      settingSources: ["user", "project", "local"]
    } });
    try { await probe.initializationResult(); }
    finally { probe.close(); }
  }
  async send(prompt: string): Promise<void> {
    this.controller = new AbortController();
    this.bridge.enableActivity();
    if (!this.team) {
      this.team = new ClaudeTeam(this.bridge);
    }
    this.current = this.makeQuery({
      prompt,
      options: {
        cwd: this.bridge.cwd, pathToClaudeCodeExecutable: this.executable,
        settingSources: ["user", "project", "local"], systemPrompt: { type: "preset", preset: "claude_code" },
        permissionMode: "default", model: this.model, resume: this.resume,
        abortController: this.controller,
        canUseTool: async (tool, input, context) => {
          const question = tool === "AskUserQuestion";
          const questions = question ? claudeQuestions(input) : [];
          const permissionOptions = question ? [] : claudePermissionOptions(context.suggestions);
          const response = await this.bridge.ask({
            kind: question ? "question" : "permission",
            title: question ? "Claude needs your answer" : `Allow ${tool}?`,
            detail: [context.decisionReason, detail(input)].filter(Boolean).join("\n\n"),
            questions,
            permissionOptions,
            autoEligible: !context.decisionReason && !context.blockedPath && await safeRead(this.bridge.cwd, tool, input)
          }, context.signal);
          if (response.decision === "deny") return { behavior: "deny", message: "User declined in Notify." };
          if (question) {
            const answers = Object.fromEntries(questions.map(q => [q.text, (response.answers?.[q.id] ?? []).join(", ")]));
            return { behavior: "allow", updatedInput: { ...input, answers } };
          }
          if (response.permissionOptionID) {
            if (response.automatic || !permissionOptions.some(option => option.id === response.permissionOptionID)) {
              throw new Error("This permission scope was not offered by Claude.");
            }
            return { behavior: "allow", updatedInput: input, updatedPermissions: context.suggestions };
          }
          return { behavior: "allow", updatedInput: input };
        },
        onElicitation: (request, context) => request.mode === "url"
          ? urlConsent(this.bridge, request.message, request.url, context.signal)
          : askForm(this.bridge, request.message, request.requestedSchema, context.signal)
      }
    });
    try {
      for await (const message of this.current) {
        if ("session_id" in message) {
          this.resume = message.session_id;
          this.bridge.setTitle("", String(message.session_id));
        }
        // Subagent tracking for launcher sessions.
        if (message.type === "system" && object(message)) {
          if (message.subtype === "task_started") {
            this.team?.started(message as Record<string, unknown>);
          }
          if (message.subtype === "task_notification") {
            const status = String((message as Record<string, unknown>).status ?? "");
            if (["completed", "failed", "stopped"].includes(status)) {
              this.team?.stopped(message as Record<string, unknown>);
            }
          }
        }
        if (message.type === "assistant") {
          const paragraphs: string[] = [];
          for (const block of message.message.content) {
            if (block.type === "text") {
              paragraphs.push(block.text);
              this.bridge.output(block.text + "\n");
            } else if (block.type === "tool_use") this.bridge.setState("working", `Using ${block.name}`);
          }
          const response = paragraphs.join("\n");
          if (response.trim()) {
            this.bridge.activity({
              id: message.uuid, kind: "assistant", title: "Agent response",
              detail: boundActivityText(response), status: "complete", timestamp: new Date().toISOString(),
              ...(message.parent_tool_use_id ? { agentID: message.parent_tool_use_id } : {})
            });
          }
        }
        if (message.type === "result" && message.is_error) {
          throw new Error("errors" in message ? message.errors.join("\n") : message.result);
        }
      }
      console.log(`\nClaude session: ${this.resume}`);
    } finally {
      this.bridge.pending.discardAll();
      this.current.close();
      this.current = undefined;
    }
  }
  async stop(): Promise<void> {
    this.team?.stop();
    this.team = undefined;
    this.bridge.pending.discardAll();
    this.controller?.abort();
    this.current?.close();
  }
}

export class CopilotAgent {
  private client: CopilotClient;
  private session?: CopilotSession;
  private team?: ReturnType<typeof attachSubagents>;
  private activity?: ActivityFeed;
  constructor(private bridge: Bridge, executable: string, private model?: string, private resume?: string) {
    this.client = new CopilotClient({ connection: RuntimeConnection.forStdio({ path: executable }), workingDirectory: bridge.cwd });
  }
  async start(): Promise<void> {
    await this.client.start();
    const config: SessionConfig = {
      workingDirectory: this.bridge.cwd, model: this.model, streaming: true,
      onPermissionRequest: async (request, context) => {
        const autoEligible = request.kind === "read" && !request.managedApprovalRequired &&
          !context.managedSettingsEnabled && !request.requestSandboxBypass &&
          await safeRead(this.bridge.cwd, "Read", { file_path: request.path });
        let options: ScopedOption[] = [];
        try {
          if (this.session) options = await scopedOptions(this.session, context.promptRequest, this.bridge.cwd);
        } catch (error) { this.bridge.error(`Additional approval scopes unavailable: ${String(error)}`); }
        let selectedResult: ReturnType<typeof selectedPermissionOption> | undefined;
        const response = await this.bridge.ask({
          kind: "permission", title: `Allow ${request.kind}?`, detail: detail(context.promptRequest ?? request), autoEligible, questions: [], supportsFeedback: true,
          permissionOptions: options.map(({ result, ...option }) => option)
        }, undefined, async reply => {
          if (!reply.permissionOptionID) return;
          if (!this.session) throw new Error("Copilot session disconnected before scoped approval.");
          selectedResult = selectedPermissionOption(options, await scopedOptions(this.session, context.promptRequest, this.bridge.cwd), reply);
        });
        if (response.permissionOptionID) {
          if (!selectedResult) throw new Error("Scoped approval was not validated.");
          return selectedResult;
        }
        return response.decision === "allow"
          ? { kind: "approve-once", approvedInteractively: response.automatic !== true }
          : { kind: "reject", feedback: response.feedback?.trim() ?? "User declined in Notify." };
      },
      onUserInputRequest: async request => {
        const question: Question = { id: "0", text: request.question, multiple: false, allowFreeform: request.allowFreeform !== false,
          options: (request.choices ?? []).map(label => ({ label, description: "" })) };
        const response = await this.bridge.ask({
          kind: "question", title: request.question, detail: "", autoEligible: false, questions: [question]
        });
        const answer = response.decision === "deny" ? "User declined to answer." : response.answers?.["0"]?.[0] ?? "";
        return { answer, wasFreeform: !request.choices?.includes(answer) };
      },
      onElicitationRequest: request => request.mode === "url"
        ? urlConsent(this.bridge, request.message, request.url)
        : askForm(this.bridge, request.message, request.requestedSchema, undefined, request.elicitationSource === undefined),
      onExitPlanModeRequest: async request => {
        const response = await this.bridge.ask({
          kind: "question", title: "Review the plan", detail: request.planContent ?? request.summary, autoEligible: false,
          questions: [{ id: "0", text: request.summary, multiple: false, allowFreeform: false,
            options: request.actions.map(label => ({ label, description: "" })) }]
        });
        return { approved: response.decision === "answer", selectedAction: response.answers?.["0"]?.[0] };
      }
    };
    this.session = this.resume ? await this.client.resumeSession(this.resume, config) : await this.client.createSession(config);
    this.bridge.setTitle("", this.session.sessionId);
    this.team = attachSubagents(this.session, this.bridge);
    void this.team.refresh();
    this.activity = new ActivityFeed(entry => this.bridge.activity(entry));
    this.bridge.enableActivity();
    console.log(`Copilot session: ${this.session.sessionId}`);
    this.session.on(event => {
      this.activity?.receive(event);
      if (event.type === "assistant.message_delta") this.bridge.output(event.data.deltaContent);
      else if (event.type === "session.title_changed") this.bridge.setTitle(event.data.title, this.session!.sessionId);
      else if (event.type === "tool.execution_start") this.bridge.setState("working", `Using ${event.data.toolName}`);
      else if (event.type === "session.error") this.bridge.error(event.data.message);
    });
  }
  async send(prompt: string): Promise<void> {
    if (!this.session) await this.start();
    try {
      await this.session!.sendAndWait({ prompt }, 86_400_000);
      this.bridge.output("\n");
    } finally { this.bridge.pending.discardAll(); }
  }
  async stop(): Promise<void> {
    this.team?.stop();
    this.activity?.stop();
    this.bridge.pending.discardAll();
    if (this.session) await this.session.disconnect();
    const errors = await this.client.stop();
    for (const error of errors) console.error(`Notify: ${error.message}`);
  }
}
