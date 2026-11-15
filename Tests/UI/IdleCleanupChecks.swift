import AppKit
import NotifyCore

@MainActor enum IdleCleanupChecks {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notify-idle-check-\(UUID())")
        let suite = "notify-idle-check-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = Store(directory: root, defaults: defaults)
        var clients: [Process] = []
        defer {
            for client in clients where client.isRunning { client.terminate() }
            wait { clients.allSatisfy { !$0.isRunning } }
            store.stop()
            defaults.removePersistentDomain(forName: suite)
            try! FileManager.default.removeItem(at: root)
        }
        func receive(_ packet: [String: Any]) throws {
            store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: JSONSerialization.data(withJSONObject: packet)))
        }
        var ready = false
        store.server.onReady = { ready = true }
        try store.server.start()
        wait { ready }
        for id in ["cleanup-one", "cleanup-two"] {
            let client = Process()
            client.executableURL = AgentSetup.findExecutable("node", path: AgentSetup.searchPath)
            client.arguments = ["Tests/UI/automation-fixture.mjs", root.path, id]
            try client.run()
            clients.append(client)
        }
        wait { store.sessions.filter { $0.canCleanupIdleSubagents && $0.team != nil }.count == 2 }
        for (id, agent) in [("unsupported", "claude"), ("busy", "copilot")] {
            try receive(["type": "hello", "sessionID": id, "agent": agent])
            try receive(["type": "capabilities", "sessionID": id, "steering": true, "idleSubagentCleanup": true])
            try receive(["type": "team", "sessionID": id, "team": [
                "agents": [], "runningCount": 0, "idleCount": 0, "truncated": false
            ]])
        }
        store.steeringWorkspace.setDraft("Keep this main draft", sessionID: "cleanup-one")
        store.steeringWorkspace.setDraft("Pending synthetic command", sessionID: "busy")
        _ = try store.steeringWorkspace.begin(session: store.registry.sessions["busy"]!, action: "queue")
        let attempts = store.stopIdleSubagents()
        precondition(attempts.count == 4 && attempts.filter { $0.commandID != nil }.count == 2,
                     "Global cleanup must visit both supported sessions and explicitly skip busy/unsupported sessions")
        precondition(store.stopIdleSubagents().allSatisfy { $0.commandID == nil },
                     "A repeated click while delivering must not dispatch another batch")
        wait {
            attempts.filter { $0.commandID != nil }.allSatisfy {
                store.steeringWorkspace.receipt(sessionID: $0.sessionID, commandID: $0.commandID!)?.status == "cleaned"
            }
        }
        for id in ["cleanup-one", "cleanup-two"] {
            let lines = try String(contentsOf: root.appendingPathComponent("\(id)-controls.jsonl"), encoding: .utf8).split(separator: "\n")
            precondition(lines.count == 1)
            let packet = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
            precondition(packet["action"] as? String == "stop_idle_subagents" && packet["text"] as? String == "" &&
                         packet["agentID"] == nil && packet["agentName"] == nil && packet["model"] == nil)
            precondition(store.registry.sessions[id]?.stopped == false)
        }
        precondition(store.steeringWorkspace.draft(sessionID: "cleanup-one") == "Keep this main draft")
        precondition(store.audit.filter { $0.action.contains("verified idle") }.count == 2,
                     "Each session cleanup must be audited before dispatch")
        let history = root.appendingPathComponent("history.json")
        try FileManager.default.removeItem(at: history)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: false)
        precondition(store.stopIdleSubagents().allSatisfy { $0.commandID == nil },
                     "An audit failure must prevent every cleanup dispatch")
        for id in ["cleanup-one", "cleanup-two"] {
            let lines = try String(contentsOf: root.appendingPathComponent("\(id)-controls.jsonl"), encoding: .utf8).split(separator: "\n")
            precondition(lines.count == 1, "Audit failure must not reach the socket")
        }
        print("Native global idle cleanup, exact wire, acknowledgments, duplicate and audit checks passed")
    }

    private static func wait(_ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(15)
        while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        precondition(predicate(), "Idle cleanup fixture timed out")
    }
}
