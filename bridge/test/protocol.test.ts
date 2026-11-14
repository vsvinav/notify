import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile, mkdir, symlink, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const load = () => import("../src/protocol.ts");

test("Claude questions retain multiple selections and option descriptions", async () => {
  const { claudeQuestions } = await load();
  assert.deepEqual(claudeQuestions({ questions: [{
    question: "Which checks?", header: "Checks", multiSelect: true,
    options: [{ label: "Unit", description: "Fast tests" }, { label: "Integration", description: "End to end" }]
  }] }), [{
    id: "0", text: "Which checks?", multiple: true, allowFreeform: true,
    options: [{ label: "Unit", description: "Fast tests" }, { label: "Integration", description: "End to end" }]
  }]);
  assert.throws(() => claudeQuestions({ questions: [{ question: "Missing options" }] }), /question/i);
});

test("responses must match the exact request and satisfy every question", async () => {
  const { validateReply } = await load();
  const request = {
    id: "request-1", kind: "question", title: "Choose", detail: "", autoEligible: false,
    questions: [{ id: "0", text: "Choose", multiple: false, allowFreeform: false,
      options: [{ label: "A", description: "" }, { label: "B", description: "" }] }]
  };
  assert.equal(validateReply(request, { requestID: "request-2", decision: "answer", answers: { "0": ["A"] } }), false);
  assert.equal(validateReply(request, { requestID: "request-1", decision: "allow" }), false);
  assert.equal(validateReply(request, { requestID: "request-1", decision: "answer", answers: { "0": ["A", "B"] } }), false);
  assert.equal(validateReply(request, { requestID: "request-1", decision: "answer", answers: { "0": ["C"] } }), false);
  assert.equal(validateReply(request, { requestID: "request-1", decision: "answer", answers: { "0": ["A"] } }), true);
  assert.equal(validateReply({ ...request, kind: "permission", questions: [] }, { requestID: "request-1", decision: "allow" }), true);
});

test("denial feedback requires explicit permission support and bounded nonempty text", async () => {
  const { validateReply } = await load();
  const request = { id: "feedback", kind: "permission", title: "Allow?", detail: "", autoEligible: false,
    supportsFeedback: true, questions: [] };
  const reply = { requestID: request.id, decision: "deny", feedback: "  Use the existing fixture.\nDo not delete it.  " };
  assert.equal(validateReply(request, reply), true);
  assert.equal(validateReply(request, { ...reply, feedback: "x".repeat(4000) }), true);
  assert.equal(validateReply(request, { requestID: request.id, decision: "deny" }), true);
  for (const feedback of ["", " \n\t ", "x".repeat(4001), 123, null, ["No"]]) {
    assert.equal(validateReply(request, { ...reply, feedback }), false);
  }
  for (const decision of ["allow", "answer"]) assert.equal(validateReply(request, { ...reply, decision }), false);
  for (const supportsFeedback of [undefined, false, "true"]) {
    assert.equal(validateReply({ ...request, supportsFeedback }, reply), false);
  }
  assert.equal(validateReply({ ...request, kind: "question" }, reply), false);
});

test("auto-yes only permits canonical project reads, never secrets or symlink escapes", async () => {
  const { safeRead } = await load();
  const root = await mkdtemp(join(tmpdir(), "notify-policy-"));
  try {
    const project = join(root, "project");
    await mkdir(project);
    await writeFile(join(project, "index.ts"), "export {}");
    await writeFile(join(project, ".env"), "NOT_A_REAL_SECRET=example");
    await writeFile(join(root, "outside.txt"), "outside");
    await symlink(join(root, "outside.txt"), join(project, "linked.txt"));
    assert.equal(await safeRead(project, "Read", { file_path: join(project, "index.ts") }), true);
    assert.equal(await safeRead(project, "Read", { file_path: join(project, ".env") }), false);
    assert.equal(await safeRead(project, "Read", { file_path: join(project, "linked.txt") }), false);
    assert.equal(await safeRead(project, "Bash", { command: "cat index.ts" }), false);
    assert.equal(await safeRead(project, "Read", { file_path: "/missing-file" }), false);
  } finally {
    await rm(root, { recursive: true });
  }
});

test("structured forms preserve typed answers and optional fields", async () => {
  const { formQuestions, formContent } = await load();
  const schema = { type: "object", required: ["enabled", "count"], properties: {
    enabled: { type: "boolean", title: "Enable it?" },
    count: { type: "integer", minimum: 1, maximum: 3 },
    note: { type: "string" }
  } };
  const questions = formQuestions(schema);
  assert.equal(questions[2].required, false);
  assert.deepEqual(formContent(schema, { enabled: ["Yes"], count: ["2"] }), { enabled: true, count: 2 });
  assert.throws(() => formContent(schema, { enabled: ["Yes"], count: ["8"] }), /count/);
  assert.throws(() => formContent(schema, { enabled: ["Yes"], count: ["1.5"] }), /count/);
});

test("required multi-select can explicitly select none when the schema allows it", async () => {
  const { formQuestions, formContent, validateReply } = await load();
  const schema = { type: "object", required: ["checks"], properties: {
    checks: { type: "array", minItems: 0, items: { type: "string", enum: ["Unit"] } }
  } };
  const questions = formQuestions(schema);
  assert.equal(validateReply({ id: "q", kind: "question", title: "", detail: "", autoEligible: false, questions },
    { requestID: "q", decision: "answer", answers: { checks: [] } }), true);
  assert.deepEqual(formContent(schema, { checks: [] }), { checks: [] });
});

test("Copilot suggested choices allow Other while external MCP enums stay closed", async () => {
  const { formQuestions, formContent } = await load();
  const schema = { type: "object", required: ["choice", "checks"], properties: {
    choice: { type: "string", enum: ["A", "B"] },
    checks: { type: "array", items: { type: "string", enum: ["Unit", "Integration"] } }
  } };
  const answers = { choice: ["My own approach"], checks: ["Unit", "Manual review"] };
  assert.equal(formQuestions(schema, true).every(question => question.allowFreeform), true);
  assert.deepEqual(formContent(schema, answers, true), { choice: "My own approach", checks: ["Unit", "Manual review"] });
  assert.equal(formQuestions(schema).every(question => !question.allowFreeform), true);
  assert.throws(() => formContent(schema, answers), /Invalid answer/);
});

test("Copilot Other answers retain text for boolean and numeric presentation fields", async () => {
  const { formQuestions, formContent } = await load();
  const schema = { type: "object", properties: {
    enabled: { type: "boolean" }, count: { type: "integer", maximum: 2 }
  } };
  assert.equal(formQuestions(schema, true)[0].allowFreeform, true);
  assert.deepEqual(formContent(schema, { enabled: ["Only after review"], count: ["Decide later"] }, true),
    { enabled: "Only after review", count: "Decide later" });
  assert.deepEqual(formContent(schema, { enabled: ["Yes"], count: ["3"] }, true), { enabled: true, count: 3 });
  assert.throws(() => formContent(schema, { enabled: ["Yes"], count: ["3"] }), /Invalid number/);
});
