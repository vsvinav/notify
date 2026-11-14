import Foundation
import NotifyCore

do {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notify-setup-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        do { try FileManager.default.removeItem(at: root) }
        catch { preconditionFailure("Could not clean up setup fixture: \(error)") }
    }
    let executableDirectory = root.appendingPathComponent("directory/copilot")
    try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
    let bin = root.appendingPathComponent("tools with ' quotes")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let fakeCLI = bin.appendingPathComponent("copilot")
    try Data("#!/bin/sh\nexit 99\n".utf8).write(to: fakeCLI)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
    precondition(AgentSetup.findExecutable("copilot", path: "relative:\(executableDirectory.deletingLastPathComponent().path):\(bin.path)") == fakeCLI,
                 "Setup must ignore relative PATH entries and executable directories")
    precondition(!AgentSetup.supportsNodeVersion("v22.17.0") &&
                 AgentSetup.supportsNodeVersion("v22.18.0") &&
                 AgentSetup.supportsNodeVersion("v25.2.1") &&
                 !AgentSetup.supportsNodeVersion("v22.18.0-rc.1"),
                 "Setup must distinguish compatible Node releases from old or prerelease runtimes")
    let launcher = bin.appendingPathComponent("notify")
    try Data("#!/bin/sh\nprintf '%s' \"$1\"\n".utf8).write(to: launcher)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
    let command = AgentSetup.launchCommand(launcher: launcher, agent: .claude, searchPath: bin.path)
    let task = Process(), pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", command]
    task.standardOutput = pipe
    try task.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    precondition(task.terminationStatus == 0 && String(decoding: output, as: UTF8.self) == "claude",
                 "Copied commands must safely preserve spaces and quotes in installed paths")
    let scripts = root.appendingPathComponent("bridge/dist")
    let targetHome = root.appendingPathComponent("isolated-copilot-home")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    let encodedHome = String(decoding: try JSONEncoder().encode(targetHome.path), as: UTF8.self)
    let setupModule = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("bridge/src/setup.ts")
    let encodedModule = String(decoding: try JSONEncoder().encode(setupModule.absoluteString), as: UTF8.self)
    let installer = """
    if (process.env.COPILOT_HOME !== \(encodedHome)) throw new Error("Installer must use the displayed destination, not inherited COPILOT_HOME");
    const {setupCopilot} = await import(\(encodedModule));
    await setupCopilot();
    """
    try Data(installer.utf8).write(to: scripts.appendingPathComponent("cli.js"))
    let snapshot = try AgentSetup.inspect(resources: root, copilotHome: targetHome)
    try AgentSetup.installCopilot(snapshot)
    precondition(FileManager.default.fileExists(atPath: snapshot.extensionPath.path), "Native setup must install into its displayed isolated destination")
    try AgentSetup.installCopilot(snapshot)
    try Data("// Another extension owns this file".utf8).write(to: snapshot.extensionPath)
    do {
        try AgentSetup.installCopilot(snapshot)
        preconditionFailure("Native setup must preserve an existing extension")
    } catch {
        precondition(AgentSetup.failureDescription(error).contains("Not replacing an existing extension"),
                     "Installer refusal must remain explicit")
    }
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

var framer = LineFramer(limit: 32)
let partial = try framer.append(Data("{\"x\":".utf8))
check(partial.isEmpty, "Partial frames must not decode")
let frames = try framer.append(Data("1}\n{}\n".utf8))
check(frames.count == 2, "Coalesced frames must split")
do {
    _ = try framer.append(Data(repeating: 65, count: 33))
    preconditionFailure("Oversized frames must be rejected")
} catch ProtocolError.oversized {}

let json = """
{"id":"r1","kind":"question","title":"Pick","detail":"","autoEligible":false,
"questions":[{"id":"0","text":"Pick","multiple":false,"allowFreeform":false,
"options":[{"label":"A","description":""},{"label":"B","description":""}]}]}
"""
let request = try JSONDecoder().decode(AgentRequest.self, from: Data(json.utf8))
check(!request.accepts(decision: "answer", answers: [:]), "Missing answers must be rejected")
check(!request.accepts(decision: "answer", answers: ["0": ["A", "B"]]), "Single-select cannot accept two answers")
check(!request.accepts(decision: "answer", answers: ["0": ["C"]]), "Unknown options must be rejected")
check(request.accepts(decision: "answer", answers: ["0": ["A"]]), "Valid selection must be accepted")
check(request.accepts(decision: "deny", answers: [:]), "User can decline")
check(!request.accepts(decision: "allow", answers: [:]), "Permission approval cannot answer a question")
print("Native protocol checks passed")

let scopedJSON = """
{"id":"scope","kind":"permission","title":"Allow command?","detail":"","autoEligible":false,"questions":[],
"permissionOptions":[{"id":"session","label":"Allow every time in this session","detail":"Only npm test"}]}
"""
let scopedRequest = try JSONDecoder().decode(AgentRequest.self, from: Data(scopedJSON.utf8))
var keyboard = ReplyWorkspace()
check(keyboard.choice(for: scopedRequest) == .allowOnce, "New permissions must default to Allow once")
keyboard.moveChoice(-1, for: scopedRequest)
check(keyboard.choice(for: scopedRequest) == .deny, "Up must wrap to the final visible choice")
keyboard.moveChoice(1, for: scopedRequest)
keyboard.moveChoice(1, for: scopedRequest)
check(keyboard.choice(for: scopedRequest) == .scope("session"), "Down must highlight the exact offered scope")
check(keyboard.choice(for: request) == .option(question: "0", label: "A"), "Highlights must not leak to another request")
keyboard.moveChoice(1, for: request)
keyboard.toggleOption("B", question: request.questions[0], request: request)
check(keyboard.drafts[request.id]?.answers(for: request) == ["0": ["B"]], "Keyboard selection must use the same answer draft as clicking")
check(keyboard.choice(for: request) == .send, "A completed single-choice answer must move to Send")
let multipleRequest = try JSONDecoder().decode(AgentRequest.self, from: Data(json.replacingOccurrences(of: "\"multiple\":false", with: "\"multiple\":true").utf8))
keyboard.toggleOption("A", question: multipleRequest.questions[0], request: multipleRequest)
check(keyboard.drafts[request.id]?.selections["0"] == ["B", "A"], "Multi-select must retain earlier choices")
check(keyboard.choice(for: multipleRequest) == .option(question: "0", label: "A"), "Multi-select must stay on the toggled choice, not submit early")
keyboard.resolve(scopedRequest.id)
check(keyboard.choice(for: scopedRequest) == .allowOnce, "Resolved scope highlights must be discarded")
let invalidScope = scopedJSON.replacingOccurrences(of: "\"id\":\"session\"", with: "\"id\":\"\"")
let invalidScopedRequest = try JSONDecoder().decode(AgentRequest.self, from: Data(invalidScope.utf8))
check(!invalidScopedRequest.isValid, "Invalid permission choice identities must be rejected")
check(scopedRequest.accepts(decision: "allow", answers: [:], permissionOptionID: "session"), "Offered permission scopes must be accepted")
check(!scopedRequest.accepts(decision: "allow", answers: [:], permissionOptionID: "forged"), "Unknown permission scopes must be rejected")
check(!scopedRequest.accepts(decision: "deny", answers: [:], permissionOptionID: "session"), "Denials cannot carry permission grants")
let feedbackRequest = try JSONDecoder().decode(AgentRequest.self, from: Data(scopedJSON.replacingOccurrences(of: "\"questions\":[]", with: "\"questions\":[],\"supportsFeedback\":true").utf8))
check(feedbackRequest.accepts(decision: "deny", answers: [:], feedback: "Use the existing test command instead."), "Offered denial feedback must reach the agent")
check(!scopedRequest.accepts(decision: "deny", answers: [:], feedback: "Different command"), "Legacy adapters must not silently discard feedback")
check(!feedbackRequest.accepts(decision: "allow", answers: [:], feedback: "Different command"), "Feedback must never accompany approval")
check(!feedbackRequest.accepts(decision: "deny", answers: [:], feedback: " \n"), "Blank instructions must be rejected")
check(!feedbackRequest.accepts(decision: "deny", answers: [:], feedback: String(repeating: "x", count: 4001)), "Oversized instructions must be rejected")

var registry = SessionRegistry()
registry.register(id: "s1", agent: "claude", cwd: "/project")
try registry.add(request, to: "s1")
check(registry.sessions["s1"]?.state == "waiting", "Pending questions must show waiting")
check(!registry.canReply(sessionID: "other", requestID: "r1", decision: "deny", answers: [:]), "Cross-session replies must fail")
check(registry.canReply(sessionID: "s1", requestID: "r1", decision: "answer", answers: ["0": ["A"]]), "Matching reply must pass")
registry.disconnect("s1")
check(!registry.canReply(sessionID: "s1", requestID: "r1", decision: "answer", answers: ["0": ["A"]]), "Disconnected prompts cannot be answered")
registry.register(id: "s1", agent: "claude", cwd: "/project")
check(registry.sessions["s1"]?.requests.isEmpty == true, "Reconnect must wait for replay rather than revive stale prompts")
try registry.add(request, to: "s1")
registry.resolve(sessionID: "s1", requestID: "r1")
check(!registry.canReply(sessionID: "s1", requestID: "r1", decision: "deny", answers: [:]), "Resolved prompts cannot be replayed")
print("Native session correlation checks passed")

let emptyArrayJSON = """
{"id":"q0","kind":"question","title":"Checks","detail":"","autoEligible":false,
"questions":[{"id":"checks","text":"Checks","multiple":true,"minimumSelections":0,"required":true,
"allowFreeform":false,"options":[{"label":"Unit","description":""}]}]}
"""
let emptyArray = try JSONDecoder().decode(AgentRequest.self, from: Data(emptyArrayJSON.utf8))
check(emptyArray.accepts(decision: "answer", answers: ["checks": []]), "Required arrays can explicitly select none")
check(!emptyArray.accepts(decision: "answer", answers: [:]), "A required field cannot be omitted")

var replies = ReplyWorkspace()
replies.update(requestIDs: ["first"])
replies.drafts["first"] = ReplyDraft(selections: ["0": ["A"]], freeText: ["1": "Draft"])
replies.drafts["first"]?.feedback = "Do not change the lockfile."
replies.update(requestIDs: ["new", "first"])
check(replies.floatingID == "first", "New arrivals cannot replace an in-progress floating reply")
replies.next(requestIDs: ["new", "first"])
check(replies.floatingID == "new", "Next request switches explicitly")
replies.update(requestIDs: ["first"])
check(replies.drafts["first"]?.freeText["1"] == "Draft", "Draft survives switching requests")
check(replies.drafts["first"]?.feedback == "Do not change the lockfile.", "Denial instructions survive switching requests")
var reconnectReplies = ReplyWorkspace()
reconnectReplies.update(requestIDs: ["first", "second"])
reconnectReplies.next(requestIDs: ["first", "second"])
reconnectReplies.update(requestIDs: [])
reconnectReplies.update(requestIDs: ["first"])
reconnectReplies.update(requestIDs: ["first", "second"])
check(reconnectReplies.floatingID == "second", "Temporary disconnect and incremental replay must preserve notification selection")
replies.resolve("first")
check(replies.drafts["first"] == nil, "Resolved drafts are removed")
print("Native reply draft checks passed")

let appearanceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("notify-colors-" + UUID().uuidString)
var appearance = try SessionAppearance.load(from: appearanceRoot)
var colored = SessionRecord(id: "transport", agent: "copilot", cwd: "/project")
colored.sourceSessionID = "saved-chat"
let originalColor = appearance.color(for: colored)
try appearance.set(0xC89FEB, for: colored, in: appearanceRoot)
check(appearance.color(for: colored) == 0xC89FEB, "Custom color must apply to the selected session")
let reloadedAppearance = try SessionAppearance.load(from: appearanceRoot)
let resumedColor = SessionRecord(id: "saved-chat", agent: "copilot", cwd: "/project")
check(reloadedAppearance.color(for: resumedColor) == 0xC89FEB, "Color follows canonical identity across transport/resume")
check(reloadedAppearance.overrides["other"] == nil, "Color changes cannot affect other sessions")
try appearance.set(nil, for: resumedColor, in: appearanceRoot)
check(appearance.color(for: colored) == originalColor, "Reset must restore the deterministic accent")
let suggestions = appearance.suggestedColors(for: colored, among: [])
var occupied: [SessionRecord] = []
for (index, color) in suggestions.enumerated() {
    var peer = SessionRecord(id: "color-peer-\(index)", agent: "copilot", cwd: "/project")
    peer.sourceSessionID = "color-chat-\(index)"
    try appearance.set(color, for: peer, in: appearanceRoot)
    occupied.append(peer)
}
var duplicate = SessionRecord(id: "same-chat-another-transport", agent: "copilot", cwd: "/project")
duplicate.sourceSessionID = occupied[0].sourceSessionID
occupied.append(duplicate)
var offline = SessionRecord(id: "offline-color", agent: "copilot", cwd: "/project")
offline.connected = false
try appearance.set(suggestions[0], for: offline, in: appearanceRoot)
occupied.append(offline)
check(appearance.suggestedColors(for: colored, among: occupied).first == suggestions[0],
      "Color usage must count connected canonical sessions once, ignoring disconnected copies")
let extraColorPeer = SessionRecord(id: "extra-color-peer", agent: "copilot", cwd: "/project")
try appearance.set(suggestions[0], for: extraColorPeer, in: appearanceRoot)
occupied.append(extraColorPeer)
check(appearance.suggestedColors(for: colored, among: occupied).first == suggestions[1],
      "The next suggestion must prefer a less-used color over its normal cycling order")
var visited = Set<UInt32>()
for _ in suggestions.indices {
    let current = appearance.color(for: colored)
    let next = appearance.suggestedColors(for: colored, among: []).first { $0 != current }!
    check(visited.insert(next).inserted, "Least-used cycling must traverse all unused choices, not bounce between two colors")
    try appearance.set(next, for: colored, in: appearanceRoot)
}
try FileManager.default.removeItem(at: appearanceRoot)

func activity(_ id: String, detail: String = "Observed output") throws -> ActivityEntry {
    try JSONDecoder().decode(ActivityEntry.self, from: JSONSerialization.data(withJSONObject: [
        "id": id, "kind": "tool", "title": "Run tests", "detail": detail, "status": "running",
        "timestamp": "2026-11-13T20:00:00Z"
    ]))
}
var timeline = SessionActivity()
try timeline.receive(activity("one"))
try timeline.receive(activity("two"))
try timeline.receive(activity("one", detail: "New output"))
check(timeline.entries.map(\.id) == ["one", "two"], "Streaming updates preserve order and deduplicate replay")
check(timeline.entries.first?.detail == "New output", "Existing timeline events update in place")
for n in 0..<330 { try timeline.receive(activity("event-\(n)", detail: String(repeating: "x", count: 16000))) }
check(timeline.entries.count <= 300 && timeline.byteCount <= 524288 && timeline.truncated,
      "Activity must bound memory and indicate truncation")
do {
    try timeline.receive(activity("", detail: "Invalid"))
    preconditionFailure("Invalid event identity must be rejected")
} catch ProtocolError.invalid {}
print("Native session appearance and bounded activity checks passed")
var workSession = SessionRecord(id: "work-summary", agent: "copilot", cwd: "/project")
try workSession.activity.receive(activity("work-action"))
check(workSession.workHeadline == "Last action: Run tests", "Idle must not be described as a currently running tool")
workSession.baseState = "working"
check(workSession.workHeadline == "Running: Run tests", "Working tool context should reach the overview")
workSession.connected = false
check(workSession.workHeadline.hasPrefix("Disconnected"), "Disconnected work must not imply current activity")

let discoveryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let liveID = UUID().uuidString, staleID = UUID().uuidString
for (id, pid) in [(liveID, 42), (staleID, 99)] {
    let directory = discoveryRoot.appendingPathComponent(id)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data().write(to: directory.appendingPathComponent("inuse.\(pid).lock"))
}
let found = try CopilotDiscovery.sessions(in: discoveryRoot, livePIDs: [42])
check(found.map(\.id) == [liveID], "Only locks belonging to live Copilot processes may appear")
let metadataPath = discoveryRoot.appendingPathComponent(liveID).appendingPathComponent("workspace.yaml")
try Data("""
name: "Fix login: handle \\"expired\\" tokens"
cwd: /projects/accounts
summary: >-
  Repair expired login tokens
  without losing the user's work.
""".utf8).write(to: metadataPath)
let labeled = try CopilotDiscovery.sessions(in: discoveryRoot, livePIDs: [42])
var catalogRegistry = SessionRegistry()
// Catalog rejects linked parents, while macOS's temporaryDirectory may use /var.
let plainRoot = discoveryRoot.resolvingSymlinksInPath()
catalogRegistry.catalog(try CopilotDiscovery.catalog(in: plainRoot, livePIDs: []))
check(catalogRegistry.sessions[liveID]?.state == "saved", "Inactive chats must not appear as live connections")
catalogRegistry.register(id: "sdk-transport", agent: "copilot", cwd: "/projects/accounts")
catalogRegistry.title("sdk-transport", text: "Resumed", sourceSessionID: liveID)
check(catalogRegistry.sessions[liveID] == nil && catalogRegistry.sessions["sdk-transport"]?.sourceSessionID == liveID,
      "Resuming through a transport must merge its saved alias")
catalogRegistry.catalog(try CopilotDiscovery.catalog(in: plainRoot, livePIDs: [42]))
check(catalogRegistry.sessions["sdk-transport"]?.ownerPID == 42 && catalogRegistry.sessions[liveID] == nil,
      "Saved chats with live owners must become setup rows, not resume candidates")
catalogRegistry.disconnect("sdk-transport")
catalogRegistry.catalog(try CopilotDiscovery.catalog(in: plainRoot, livePIDs: []))
catalogRegistry.register(id: "second-sdk", agent: "copilot", cwd: "/projects/accounts")
catalogRegistry.title("second-sdk", text: "Resumed again", sourceSessionID: liveID)
check(catalogRegistry.sessions["sdk-transport"] == nil, "Repeated resume must merge the previous transport alias too")
registry.discover(labeled)
check(registry.sessions[liveID]?.name == "Fix login: handle \"expired\" tokens", "Discovery must use the real chat title, not its UUID")
check(registry.sessions[liveID]?.cwd == "/projects/accounts", "Discovery must include the project directory")
check(registry.sessions[liveID]?.synopsis == "Repair expired login tokens without losing the user's work.", "Folded YAML summaries must decode correctly")
registry.register(id: liveID, agent: "copilot", cwd: "/projects/accounts")
check(registry.sessions[liveID]?.name == "Fix login: handle \"expired\" tokens", "Attachment must preserve the saved title")
registry.disconnect(liveID)
registry.discover(found)
check(registry.sessions[liveID]?.state == "setup", "An existing terminal must not be presented as connected")
registry.discover([])
check(registry.sessions[liveID] == nil, "Exited unconnected sessions must disappear")
registry.discover(found)
registry.register(id: liveID, agent: "copilot", cwd: "/project")
registry.discover(found)
check(registry.sessions[liveID]?.connected == true, "Discovery cannot downgrade a connected extension")
check(registry.sessions[liveID]?.needsSetup == false, "The extension joins the discovered row rather than creating a duplicate")
registry.discover([])
check(registry.sessions[liveID]?.connected == true, "Scanning cannot remove connected sessions")
registry.discover(labeled)
try Data("name: [invalid\n".utf8).write(to: metadataPath)
let malformed = try CopilotDiscovery.sessions(in: discoveryRoot, livePIDs: [42])
check(malformed.first?.metadataError != nil, "Malformed metadata must surface an error, not remove the session")
registry.discover(malformed)
check(registry.sessions[liveID]?.name == "Fix login: handle \"expired\" tokens", "Bad metadata must not erase a known title")
var launcherRegistry = SessionRegistry()
launcherRegistry.discover(labeled)
launcherRegistry.register(id: "launcher-row", agent: "copilot", cwd: "/projects/accounts")
launcherRegistry.title("launcher-row", text: "", sourceSessionID: liveID)
launcherRegistry.discover(labeled)
check(launcherRegistry.sessions["launcher-row"]?.name == "Fix login: handle \"expired\" tokens", "SDK launcher rows must inherit their original saved chat title")
check(launcherRegistry.sessions.count == 1, "A launcher and its discovered session must not appear twice")
try FileManager.default.removeItem(at: discoveryRoot)
print("Native running-session discovery checks passed")

let context = RequestContext.fields(from: #"{"toolName":"shell","arguments":{"command":"echo hello\npwd","cwd":"/project"},"requiresApproval":true}"#)
check(context.contains { $0.label == "Arguments / Command" && $0.value == "echo hello\npwd" }, "Commands must be readable and retain all lines")
check(context.contains { $0.label == "Requires Approval" && $0.value == "Yes" }, "Context booleans need human-readable values")
check(RequestContext.fields(from: "A long plain-text explanation").first?.value == "A long plain-text explanation", "Plain context must remain intact")
check(RequestContext.fields(from: #"{"type":"object","properties":{"choice":{"type":"string"}}}"#, isQuestion: true).isEmpty, "Form schemas must not be dumped under already-rendered questions")
let commandContext = RequestContext.fields(from: #"{"kind":"commands","assistedApproval":{"metadata":"runtime-only"},"commandIdentifiers":["npm"],"fullCommandText":"npm test\nnpm run build","canOfferSessionApproval":true}"#)
check(commandContext.first?.label == "Full Command Text", "The actual command must come before runtime metadata")
check(commandContext.first?.presentation == .code && commandContext.first?.displayLabel == "Command", "Commands need code formatting and a useful label")
check(commandContext.filter(\.isDecisionDetail).count == 1, "Runtime identifiers must stay available without obscuring the command")
let uriContext = RequestContext.fields(from: #"{"toolName":"read_resource","serverName":"docs","arguments":{"debug":false,"uri":"docs://reference/auth?version=2#examples"}}"#)
check(uriContext.first?.value == "docs://reference/auth?version=2#examples",
      "The exact requested URI must precede tool metadata and secondary arguments")
let resourceContext = RequestContext.fields(from: #"{"requestSandboxBypass":true,"arguments":{"resourceURI":["https://example.org/a%2Fb?x=1&y=2","file:///project/notes.txt"]},"toolName":"read_resource"}"#)
check(resourceContext.first?.presentation == .warning, "Prominent resource targets must not outrank explicit warnings")
check(resourceContext.dropFirst().prefix(2).map(\.value) == ["https://example.org/a%2Fb?x=1&y=2", "file:///project/notes.txt"],
      "Nested URI arrays must preserve every exact scheme, path, query and fragment")
let warningContext = RequestContext.fields(from: #"{"fullCommandText":"echo example","requestSandboxBypass":true,"requestSandboxBypassReason":"Network policy blocked this command","managedApprovalRequired":true}"#)
check(warningContext.first?.label != "Full Command Text", "Explicit policy and sandbox warnings must precede the command")
check(warningContext.filter { $0.presentation == .warning }.count == 3, "Keep every supplied policy and bypass warning prominent")
let editContext = RequestContext.fields(from: #"{"file_path":"/project/main.ts","old_string":"before\n","new_string":"after\n","diff":"--- a/main.ts\n+++ b/main.ts\n-before\n+after"}"#)
check(editContext.first?.value == "/project/main.ts", "File changes must identify the affected path")
check(editContext.first(where: { $0.presentation == .diff })?.value.hasSuffix("+after") == true, "Supplied diff content must be retained exactly")
check(editContext.first(where: { $0.displayLabel == "Text to replace" })?.value == "before\n", "Replacement snippets must not be mislabeled as whole files")
let legacyClaude = RequestContext.fields(from: "Approval required for this command.\n\n{\"command\":\"npm test\"}")
check(legacyClaude.contains { $0.displayLabel == "Permission reason" && $0.value == "Approval required for this command." },
      "Existing Claude reason-plus-JSON payloads must keep the reason readable")
check(legacyClaude.contains { $0.label == "Command" && $0.presentation == .code && $0.value == "npm test" },
      "Existing Claude commands must render as code, not embedded JSON")
print("Native readable-context checks passed")

let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let description = SessionDescription(text: "Repairs login validation.", model: "claude-haiku-4.5", generatedAt: Date())
try DescriptionCache.save([liveID: description], in: cacheRoot)
let cachedDescriptions = try DescriptionCache.load(from: cacheRoot)
check(cachedDescriptions[liveID]?.text == description.text, "Descriptions must survive app restarts")
let cacheMode = try FileManager.default.attributesOfItem(atPath: cacheRoot.appendingPathComponent("descriptions.json").path)[.posixPermissions] as? NSNumber
check(cacheMode?.intValue == 0o600, "AI descriptions must be saved privately")
try FileManager.default.removeItem(at: cacheRoot)
print("Native description-cache checks passed")

let runnerRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: runnerRoot, withIntermediateDirectories: true)
let helper = runnerRoot.appendingPathComponent("summary-fixture.js")
try Data("""
setTimeout(() => process.stdout.write(JSON.stringify({text:"Fixture description",model:"fixture-haiku"}) + "\\n"), 40);
""".utf8).write(to: helper)
let runner = DescriptionRunner()
var result: Result<SessionDescription, Error>?
try runner.run(sessionID: liveID, script: helper) { result = $0 }
do {
    try runner.run(sessionID: liveID, script: helper) { _ in }
    preconditionFailure("A second summary must not run concurrently")
} catch ProtocolError.invalid {}
let deadline = Date().addingTimeInterval(5)
while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
check(result != nil, "Summary helper must finish without blocking the UI")
let generated = try result!.get()
check(generated.text == "Fixture description" && !runner.isRunning, "Helper output must reach the UI and clear busy state")
try Data("process.stderr.write('Fixture login failure'); process.exit(1);".utf8).write(to: helper)
result = nil
try runner.run(sessionID: liveID, script: helper) { result = $0 }
while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
guard case .failure(let runnerError) = result else { preconditionFailure("A failed helper must not report success") }
check(runnerError.localizedDescription.contains("Fixture login failure"), "Helper errors must be actionable")
try FileManager.default.removeItem(at: runnerRoot)
print("Native on-demand process checks passed")

var controlled = SessionRecord(id: "controlled", agent: "copilot", cwd: "/project")
var controls = SteeringWorkspace()
do {
    _ = try controls.begin(session: controlled, action: "queue")
    preconditionFailure("Unadvertised steering cannot be used")
} catch ProtocolError.invalid {}
controlled.canSteer = true
controlled.canAutoYes = true
controls.drafts[controlled.id] = "Keep the public API unchanged"
let commandID = try controls.begin(session: controlled, action: "queue")
controls.update(sessionID: controlled.id, commandID: "wrong", status: "received", text: "Wrong session")
check(controls.receipts[controlled.id]?.status == "sending", "Only the matching control receipt can resolve delivery")
controls.update(sessionID: controlled.id, commandID: commandID, status: "received", text: "Received")
controls.update(sessionID: controlled.id, commandID: commandID, status: "queued", text: "Late acknowledgment")
check(controls.receipts[controlled.id]?.status == "received", "Queue acknowledgments must not replace receipt confirmation")
check(controls.drafts[controlled.id] == "", "Acknowledged drafts clear only after acceptance")
controls.drafts[controlled.id] = "Next direction"
_ = try controls.begin(session: controlled, action: "queue")
controls.disconnect(controlled.id)
check(controls.receipts[controlled.id]?.status == "unknown", "Lost delivery must not look successful")
check(controls.drafts[controlled.id] == "Next direction", "Unknown delivery must preserve the draft")
var automation = SessionAutomation()
let broadPermission = try JSONDecoder().decode(AgentRequest.self, from: Data("""
{"id":"broad","kind":"permission","title":"Allow shell?","detail":"touch file","autoEligible":false,"sessionAutoEligible":true,"questions":[]}
""".utf8))
check(automation.scope(for: broadPermission, session: controlled, safeEnabled: true, muted: false) == nil, "Broad Auto-yes starts off")
try automation.setEnabled(true, for: controlled)
check(automation.scope(for: broadPermission, session: controlled, safeEnabled: false, muted: false) == "session", "Explicit session mode can approve eligible permissions")
check(automation.scope(for: request, session: controlled, safeEnabled: true, muted: false) == nil, "Auto-yes must never answer questions")
automation.disable(controlled.id)
check(automation.scope(for: broadPermission, session: controlled, safeEnabled: true, muted: false) == nil, "Disconnect/stop disable broad approval")
try automation.setEnabled(true, for: controlled)
try automation.setDangerousEnabled(true, for: controlled)
check(!automation.enabled.contains(controlled.id) && automation.dangerous.contains(controlled.id), "Dangerous mode replaces normal session Auto-yes")
check(automation.scope(for: broadPermission, session: controlled, safeEnabled: false, muted: true) == "session", "Explicit dangerous mode uses only advertised tool eligibility")
check(automation.scope(for: request, session: controlled, safeEnabled: false, muted: false) == nil, "Dangerous mode must never invent question answers")
var otherControlled = SessionRecord(id: "different-session", agent: "copilot", cwd: "/fixture")
otherControlled.canAutoYes = true
check(automation.scope(for: broadPermission, session: otherControlled, safeEnabled: false, muted: false) == nil, "Dangerous opt-in must not affect another session")
try automation.setEnabled(true, for: controlled)
check(automation.dangerous.isEmpty && automation.enabled.contains(controlled.id), "Normal mode replaces dangerous mode")
try automation.setDangerousEnabled(true, for: controlled)
automation.disable(controlled.id)
check(automation.activeIDs.isEmpty, "Disconnect/stop clear both kinds of session approval")
print("Native steering and explicit Auto-yes checks passed")
