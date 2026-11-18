import AppKit
import SwiftUI
import NotifyCore
import Vision

@MainActor enum ClaudeNativeChecks {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notify-claude-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "notify-claude-ui-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: root) }
            catch { preconditionFailure("Could not clean Claude fixture: \(error)") }
        }
        let store = Store(directory: root.appendingPathComponent("Library/Application Support/Notify"), defaults: defaults)
        defer { store.stop() }
        let session = SessionRecord(id: UUID().uuidString, agent: "claude", cwd: root.path)
        let summaryText = try text(SessionDescriptionView(store: store, session: session), width: 600, height: 180)
        precondition(summaryText.contains("Summarize"), "Claude must expose the same explicit summary action as Copilot")

        let resources = root.appendingPathComponent("resources"), bin = resources.appendingPathComponent("bin")
        let scripts = resources.appendingPathComponent("bridge/dist")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        for name in ["node", "copilot", "claude", "notify"] {
            let path = bin.appendingPathComponent(name)
            try Data("""
            #!/bin/sh
            if [ "$1" = '--version' ]; then echo 'v22.18.0'
            elif [ "$2" = 'setup-claude' ]; then echo 'Fixture Claude hook failure' >&2; exit 1
            fi
            """.utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        }
        try Data().write(to: scripts.appendingPathComponent("cli.js"))
        try Data().write(to: scripts.appendingPathComponent("claude-hook.js"))
        let snapshot = try AgentSetup.inspect(resources: resources, path: bin.path,
            copilotHome: root.appendingPathComponent("copilot"), claudeHome: root.appendingPathComponent("claude"))
        store.setupSnapshot = snapshot
        store.installCopilotExtension()
        wait("Copilot setup fixture") { !store.setupBusy }
        store.setupSnapshot = snapshot
        store.setupAgent = .claude
        let claudeSetup = try text(AgentSetupView(store: store), width: 960, height: 620)
        precondition(!claudeSetup.contains("Hooks installed") && !claudeSetup.contains("Hooks are present"),
                     "Installing Copilot must not claim Claude hooks are installed")
        precondition(claudeSetup.contains("idle") && claudeSetup.contains("Add hooks"),
                     "Ready Claude setup must show its action and safe idle-only reload guidance")
        if let index = CommandLine.arguments.firstIndex(of: "--capture"), CommandLine.arguments.count > index + 1 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                _ = try text(AgentSetupView(store: store), width: 960, height: 620,
                             capture: directory.appendingPathComponent("claude-ready-\(name).png"))
            }
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        store.installClaudeHooks()
        store.setupAgent = .copilot
        wait("Claude setup fixture") { !store.setupBusy }
        let copilotSetup = try text(AgentSetupView(store: store), width: 960, height: 620)
        precondition(!copilotSetup.contains("Fixture Claude hook failure"),
                     "Claude installer errors must stay on the Claude setup surface")
        store.setupAgent = .claude
        let failedClaudeSetup = try text(AgentSetupView(store: store), width: 960, height: 620)
        precondition(failedClaudeSetup.contains("Fixture Claude hook failure"))
        try Data("#!/bin/sh\nprintf 'v22.18.0\\n'\n".utf8).write(to: bin.appendingPathComponent("node"))
        store.setupSnapshot = snapshot
        store.installClaudeHooks()
        wait("Successful Claude setup fixture") { !store.setupBusy }
        store.setupSnapshot = snapshot
        let installedClaudeSetup = try text(AgentSetupView(store: store), width: 960, height: 620)
        precondition(installedClaudeSetup.contains("Hooks installed") && installedClaudeSetup.contains("idle"),
                     "Installed hooks must retain existing-terminal reload guidance")
        try hookRoundtrip(store: store, home: root)
        print("Claude native setup, summary affordance and production hook roundtrip passed")
    }

    private static func hookRoundtrip(store: Store, home: URL) throws {
        let script = ProcessInfo.processInfo.environment["NOTIFY_CLAUDE_HOOK"]
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("bridge/dist/claude-hook.js").path
        let node = AgentSetup.findExecutable("node", path: AgentSetup.searchPath)!
        let id = UUID().uuidString.lowercased(), transcript = home.appendingPathComponent("transcript.jsonl")
        try Data().write(to: transcript)
        var processes: [Process] = []
        defer {
            for process in processes where process.isRunning { process.terminate() }
            wait("Owned Claude fixture shutdown") { processes.allSatisfy { !$0.isRunning } }
        }
        func launch(_ arguments: [String], event: [String: Any]? = nil) throws -> (Process, Pipe) {
            let process = Process(), input = Pipe(), output = Pipe()
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = home.path
            environment["CLAUDE_CONFIG_DIR"] = home.appendingPathComponent("claude").path
            environment["NODE_TLS_REJECT_UNAUTHORIZED"] = "1"
            process.executableURL = node
            process.arguments = [script] + arguments
            process.environment = environment
            process.standardInput = input; process.standardOutput = output
            try process.run()
            processes.append(process)
            if let event { try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: event)) }
            try input.fileHandleForWriting.close()
            return (process, output)
        }
        func hook(_ name: String, extra: [String: Any] = [:]) throws -> (Process, Pipe) {
            var event: [String: Any] = ["session_id": id, "hook_event_name": name, "cwd": home.path,
                                        "transcript_path": transcript.path]
            event.merge(extra) { _, value in value }
            return try launch([], event: event)
        }
        var ready = false
        store.server.onReady = { ready = true }
        try store.server.start()
        wait("Native listener") { ready }
        _ = try launch(["--serve", id, home.path, String(ProcessInfo.processInfo.processIdentifier), transcript.path])
        wait("Claude registration") { store.sessions.contains { $0.agent == "claude" && $0.connected } }
        for tool in ["Bash", "AskUserQuestion"] {
            let input: [String: Any] = tool == "Bash" ? ["command": "synthetic command, never executed"] :
                ["questions": [["question": "Pick a fixture", "options": [["label": "A"], ["label": "B"]]]]]
            let (process, output) = try hook("PermissionRequest", extra: ["tool_name": tool, "tool_input": input])
            wait("Claude native decision") { store.pending.count == 1 }
            let pending = store.pending[0]
            precondition(pending.session.agent == "claude" && !pending.session.canSteer &&
                         !pending.session.canStopSubagents && !pending.session.canCreateSubagents,
                         "Original Claude terminals must not advertise unsupported controls")
            if tool == "Bash" {
                store.reply(session: pending.session.id, request: pending.request, decision: "deny", feedback: "Fixture denial")
            } else {
                store.reply(session: pending.session.id, request: pending.request, decision: "answer", answers: ["0": ["Custom answer"]])
            }
            wait("Claude native reply delivery") { !process.isRunning && store.pending.isEmpty && store.sending.isEmpty }
            precondition(process.terminationStatus == 0)
            let response = try JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as! [String: Any]
            let decision = (response["hookSpecificOutput"] as! [String: Any])["decision"] as! [String: Any]
            if tool == "Bash" {
                precondition(decision["behavior"] as? String == "deny" && decision["message"] as? String == "Fixture denial")
            } else {
                let updated = decision["updatedInput"] as! [String: Any]
                precondition((updated["answers"] as? [String: String])?["Pick a fixture"] == "Custom answer")
            }
        }
        let (teamEvent, _) = try hook("SubagentStart", extra: ["agent_id": "fixture-helper", "agent_type": "Explore"])
        wait("Claude subagent team") { !teamEvent.isRunning && store.sessions.contains { $0.team?.agents.first?.id == "fixture-helper" } }
        let message: [String: Any] = ["type": "assistant", "uuid": "fixture-response",
            "message": ["content": [["type": "text", "text": "Native Claude response"]]]]
        try (JSONSerialization.data(withJSONObject: message) + Data("\n".utf8)).write(to: transcript)
        wait("Claude native conversation") { store.sessions.contains { $0.output.contains("Native Claude response") } }
        precondition(store.audit.count >= 2 && store.requestErrors.isEmpty, "Claude replies must retain native auditing")
        let (end, _) = try hook("SessionEnd")
        wait("Claude session end") { !end.isRunning && store.sessions.allSatisfy { !$0.connected } }
    }

    private static func wait(_ label: String, _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(15)
        while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        precondition(predicate(), "\(label) timed out")
    }

    private static func text<V: View>(_ content: V, width: CGFloat, height: CGFloat, capture: URL? = nil) throws -> String {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: content.frame(width: width, height: height)
            .background(Palette.surface).foregroundStyle(Palette.ink))
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        let image = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: image)
        if let capture {
            guard let data = image.representation(using: .png, properties: [:]) else {
                preconditionFailure("Could not encode Claude setup capture")
            }
            try data.write(to: capture)
        }
        let request = VNRecognizeTextRequest()
        try VNImageRequestHandler(cgImage: image.cgImage!, options: [:]).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
    }
}
