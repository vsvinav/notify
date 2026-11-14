import { realpath, stat } from "node:fs/promises";
import { relative, resolve, isAbsolute } from "node:path";

export interface Question {
  id: string;
  text: string;
  multiple: boolean;
  allowFreeform: boolean;
  required?: boolean;
  minimumSelections?: number;
  options: { label: string; description: string }[];
}

export interface Request {
  id: string;
  kind: "permission" | "question";
  title: string;
  detail: string;
  autoEligible: boolean;
  sessionAutoEligible?: boolean;
  supportsFeedback?: boolean;
  questions: Question[];
  permissionOptions?: PermissionOption[];
}

export interface PermissionOption {
  id: string;
  label: string;
  detail: string;
}

export interface Reply {
  requestID: string;
  decision: "allow" | "deny" | "answer";
  answers?: Record<string, string[]>;
  automatic?: boolean;
  approvalScope?: "safe-read" | "session";
  cancelled?: boolean;
  permissionOptionID?: string;
  feedback?: string;
}

export function object(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function claudeQuestions(input: Record<string, unknown>): Question[] {
  if (!Array.isArray(input.questions) || !input.questions.length) throw new Error("Invalid Claude questions");
  return input.questions.map((q: unknown, index) => {
    if (!object(q) || typeof q.question !== "string" || !Array.isArray(q.options)) {
      throw new Error("Unsupported Claude question format");
    }
    const options = q.options.map((option: unknown) => {
      if (!object(option) || typeof option.label !== "string") throw new Error("Invalid question option");
      return { label: option.label, description: typeof option.description === "string" ? option.description : "" };
    });
    return { id: String(index), text: q.question, multiple: q.multiSelect === true, allowFreeform: true, options };
  });
}

export function validateReply(request: Request, value: unknown): value is Reply {
  if (!object(value) || value.requestID !== request.id) return false;
  if (value.feedback !== undefined &&
      (request.kind !== "permission" || request.supportsFeedback !== true || value.decision !== "deny" ||
       typeof value.feedback !== "string" || !value.feedback.trim() || value.feedback.length > 4000)) return false;
  if (value.permissionOptionID !== undefined &&
      (request.kind !== "permission" || value.decision !== "allow" || value.automatic === true ||
       !request.permissionOptions?.some(option => option.id === value.permissionOptionID))) return false;
  if (value.automatic !== undefined && typeof value.automatic !== "boolean") return false;
  if (value.automatic && (request.kind !== "permission" || value.decision !== "allow")) return false;
  if (value.approvalScope !== undefined &&
      (!value.automatic || !["safe-read", "session"].includes(String(value.approvalScope)))) return false;
  if (value.decision === "deny") return true;
  if (request.kind === "permission") return value.decision === "allow";
  if (value.decision !== "answer" || !object(value.answers)) return false;
  const answers = value.answers;
  return request.questions.length > 0 && request.questions.every(q => {
    const answer = answers[q.id];
    if (q.required === false && (answer === undefined || (Array.isArray(answer) && answer.length === 0))) return true;
    return Array.isArray(answer) && answer.length >= (q.multiple ? q.minimumSelections ?? 1 : 1) &&
      (q.multiple || answer.length === 1) &&
      new Set(answer).size === answer.length &&
      answer.every((item: unknown) => typeof item === "string" && item.trim().length > 0 && item.length < 65_536 &&
        (q.allowFreeform || q.options.some(option => option.label === item)));
  });
}

function fields(schema: unknown): Record<string, unknown> {
  if (!object(schema) || !object(schema.properties)) throw new Error("Unsupported form schema");
  return schema.properties;
}

export function formQuestions(schema: unknown, agentInitiated = false): Question[] {
  const properties = fields(schema);
  const required = object(schema) && Array.isArray(schema.required) ? schema.required : [];
  return Object.entries(properties).map(([id, field]) => {
    if (!object(field) || !["string", "boolean", "number", "integer", "array"].includes(String(field.type))) {
      throw new Error(`Unsupported field: ${id}`);
    }
    const source = field.type === "array" && object(field.items) ? field.items : field;
    let options: Question["options"] = [];
    if (Array.isArray(source.enum)) {
      options = source.enum.map(value => {
        if (typeof value !== "string") throw new Error(`Unsupported enum: ${id}`);
        return { label: value, description: "" };
      });
    } else {
      const variants = source.oneOf ?? source.anyOf;
      if (Array.isArray(variants)) options = variants.map(value => {
        if (!object(value) || typeof value.const !== "string") throw new Error(`Unsupported choice: ${id}`);
        return { label: value.const, description: typeof value.title === "string" ? value.title : "" };
      });
    }
    if (field.type === "boolean") options = [{ label: "Yes", description: "" }, { label: "No", description: "" }];
    if (field.type === "array" && options.length === 0) throw new Error(`Unsupported array field: ${id}`);
    const title = typeof field.title === "string" ? field.title : id;
    return {
      id, text: title + (typeof field.description === "string" ? `\n${field.description}` : ""),
      multiple: field.type === "array", allowFreeform: agentInitiated || options.length === 0,
      required: required.includes(id), options,
      ...(field.type === "array" ? { minimumSelections: !agentInitiated && typeof field.minItems === "number" ? field.minItems : 0 } : {})
    };
  });
}

export function formContent(schema: unknown, answers: Record<string, string[]>, agentInitiated = false): Record<string, string | number | boolean | string[]> {
  const properties = fields(schema);
  const questions = formQuestions(schema, agentInitiated);
  const content: Record<string, string | number | boolean | string[]> = {};
  for (const q of questions) {
    const values = answers[q.id] ?? [];
    if (answers[q.id] === undefined && !q.required) continue;
    const field = properties[q.id];
    if (!object(field) || !validateReply({
      id: "form", kind: "question", title: "", detail: "", questions: [q], autoEligible: false
    }, { requestID: "form", decision: "answer", answers })) throw new Error(`Invalid answer for ${q.id}`);
    let value: string | number | boolean | string[] = values[0];
    // Built-in ask_user schemas describe presentation; external MCP schemas remain constraints.
    if (agentInitiated) {
      if (field.type === "array") value = values;
      else if (!values.length && !q.required) continue;
      else if (field.type === "boolean" && (value === "Yes" || value === "No")) value = value === "Yes";
      else if ((field.type === "number" || field.type === "integer") && Number.isFinite(Number(value))) value = Number(value);
      content[q.id] = value;
      continue;
    }
    if (field.type === "boolean") value = value === "Yes";
    else if (field.type === "number" || field.type === "integer") {
      value = Number(value);
      if (!Number.isFinite(value) || (field.type === "integer" && !Number.isInteger(value)) ||
        (typeof field.minimum === "number" && value < field.minimum) ||
        (typeof field.maximum === "number" && value > field.maximum)) throw new Error(`Invalid number for ${q.id}`);
    } else if (field.type === "array") {
      value = values;
      if ((typeof field.minItems === "number" && values.length < field.minItems) ||
        (typeof field.maxItems === "number" && values.length > field.maxItems)) throw new Error(`Invalid selection count for ${q.id}`);
    } else {
      if ((typeof field.minLength === "number" && value.length < field.minLength) ||
        (typeof field.maxLength === "number" && value.length > field.maxLength)) throw new Error(`Invalid length for ${q.id}`);
      if (field.format === "email" && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(value)) throw new Error(`Invalid email for ${q.id}`);
      if (field.format === "uri") {
        try { new URL(value); } catch { throw new Error(`Invalid URL for ${q.id}`); }
      }
      if ((field.format === "date" || field.format === "date-time") && Number.isNaN(Date.parse(value))) {
        throw new Error(`Invalid date for ${q.id}`);
      }
    }
    content[q.id] = value;
  }
  return content;
}

export async function safeRead(cwd: string, tool: string, input: Record<string, unknown>): Promise<boolean> {
  if (tool !== "Read" || typeof input.file_path !== "string") return false;
  try {
    const root = await realpath(cwd);
    const file = await realpath(resolve(cwd, input.file_path));
    const path = relative(root, file);
    if (!path || isAbsolute(path) || path.startsWith("..")) return false;
    const sensitive = /(^\.|secret|credential|password|token|private|^id_[a-z]|\.pem$|\.key$|\.p12$)/i;
    if (path.split("/").some(part => sensitive.test(part))) return false;
    // Only source/document files qualify; unknown formats remain manual.
    if (!/\.(ts|tsx|js|jsx|swift|py|rs|go|java|c|h|cpp|css|html|md|txt)$/i.test(path)) return false;
    return (await stat(file)).isFile();
  } catch (error) {
    if (object(error) && ["ENOENT", "EACCES", "EPERM", "ENOTDIR", "ELOOP"].includes(String(error.code))) return false;
    throw error;
  }
}
