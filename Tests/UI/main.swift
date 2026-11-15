import AppKit
import Carbon
import SwiftUI
import NotifyCore
import Vision

@main struct UIChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .aqua)
        NSApp.finishLaunching()
        if CommandLine.arguments.contains("--performance") {
            try AgentPerformanceChecks.run()
            return
        }
        ResponseRenderingChecks.run()
        SessionReorderingChecks.run()
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: "resources/Info.plist")), format: nil) as! [String: Any]
        precondition(plist["LSUIElement"] as? Bool != true, "Notify must be a normal Dock application, not a hidden menu-bar agent")
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("notify-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let suite = "notify-ui-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("dark", forKey: "appearanceMode")
        let store = Store(directory: fixtureRoot, defaults: defaults)
        do {
            let teamStore = Store(directory: fixtureRoot.appendingPathComponent("team"), defaults: defaults)
            defer { teamStore.stop() }
            func receiveTeam(_ value: [String: Any]) throws {
                teamStore.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: JSONSerialization.data(withJSONObject: value)))
            }
            try receiveTeam(["type": "hello", "sessionID": "team-session", "agent": "copilot", "cwd": "/Projects/example"])
            try receiveTeam(["type": "team", "sessionID": "team-session", "team": [
                "agents": [["id": "worker-1", "name": "Reviewer", "task": "Review the changes", "status": "running"]],
                "runningCount": 1, "idleCount": 0, "truncated": false
            ]])
            precondition(teamStore.error == nil, "Native sessions must accept authoritative subagent snapshots. Fixture: \(fixtureRoot.path)")
            precondition(teamStore.registry.sessions["team-session"]?.team?.runningCount == 1)
            try receiveTeam(["type": "team", "sessionID": "team-session", "team": [
                "agents": [], "runningCount": 0, "idleCount": 0, "truncated": false
            ]])
            precondition(teamStore.registry.sessions["team-session"]?.team?.agents.isEmpty == true,
                         "Authoritative snapshots must remove finished or vanished agents")
            try receiveTeam(["type": "hello", "sessionID": "team-session", "agent": "copilot", "cwd": "/Projects/example"])
            precondition(teamStore.registry.sessions["team-session"]?.team == nil,
                         "Reconnect must wait for a fresh snapshot instead of claiming an old running count")
            for (id, child) in [("main-reply", false), ("child-reply", true)] {
                var activity: [String: Any] = ["id": id, "kind": "assistant", "title": "Agent response",
                                               "detail": id, "status": "complete", "timestamp": ISO8601DateFormatter().string(from: Date())]
                if child { activity["agentID"] = "worker-1" }
                try receiveTeam(["type": "activity", "sessionID": "team-session", "activity": activity])
            }
            precondition(teamStore.registry.sessions["team-session"]?.output.contains("main-reply") == true &&
                         teamStore.registry.sessions["team-session"]?.output.contains("child-reply") == false,
                         "Legacy conversation context must not mislabel child responses as the main agent")
            try receiveTeam(["type": "capabilities", "sessionID": "team-session", "steering": true])
            let oldStop = try teamStore.steeringWorkspace.begin(session: teamStore.registry.sessions["team-session"]!, action: "stop")
            try receiveTeam(["type": "state", "sessionID": "team-session", "state": "working"])
            try receiveTeam(["type": "control_status", "sessionID": "team-session", "commandID": oldStop, "status": "stopped"])
            precondition(teamStore.registry.sessions["team-session"]?.stopped == false,
                         "A delayed stop acknowledgment must not freeze an agent that resumed working")
            let disconnectedStop = try teamStore.steeringWorkspace.begin(session: teamStore.registry.sessions["team-session"]!, action: "stop")
            teamStore.server.onDisconnect("team-session")
            try receiveTeam(["type": "hello", "sessionID": "team-session", "agent": "copilot", "cwd": "/Projects/example"])
            try receiveTeam(["type": "control_status", "sessionID": "team-session", "commandID": disconnectedStop, "status": "stopped"])
            precondition(teamStore.registry.sessions["team-session"]?.stopped == false,
                         "An old connection's stop must not freeze the reconnected main agent")
            for (id, child) in [("main-tool", false), ("child-tool", true)] {
                var activity: [String: Any] = ["id": id, "kind": "tool", "title": id,
                    "detail": "Reported command and result", "status": "running",
                    "timestamp": ISO8601DateFormatter().string(from: Date())]
                if child { activity["agentID"] = "worker-1" }
                try receiveTeam(["type": "activity", "sessionID": "team-session", "activity": activity])
            }
            let activitySession = teamStore.registry.sessions["team-session"]!
            precondition(AgentActivityPanel(session: activitySession, agentID: nil).reported.map(\.id) == ["main-tool"] &&
                         AgentActivityPanel(session: activitySession, agentID: "worker-1").reported.map(\.id) == ["child-tool"],
                         "The compact activity panel must show only the selected agent's reported actions")
        }
        do {
            let recovering = Store(directory: fixtureRoot.appendingPathComponent("error-recovery"), defaults: defaults)
            defer { recovering.stop() }
            func receiveErrorEvent(_ value: [String: Any]) throws {
                recovering.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: JSONSerialization.data(withJSONObject: value)))
            }
            for id in ["recovering", "other"] {
                try receiveErrorEvent(["type": "hello", "sessionID": id, "agent": "copilot", "cwd": "/Projects/example"])
                try receiveErrorEvent(["type": "error", "sessionID": id, "text": "Synthetic model DNS failure"])
            }
            try receiveErrorEvent(["type": "request", "sessionID": "recovering", "request": [
                "id": "unresolved-reply", "kind": "permission", "title": "Synthetic approval", "detail": "",
                "autoEligible": false, "questions": []
            ]])
            try receiveErrorEvent(["type": "error", "sessionID": "recovering", "requestID": "unresolved-reply",
                                   "text": "Reply delivery remains uncertain"])
            for state in ["ready", "waiting", "error"] {
                try receiveErrorEvent(["type": "state", "sessionID": "recovering", "state": state, "text": "Synthetic status"])
                precondition(recovering.sessionErrors["recovering"] == "Synthetic model DNS failure",
                             "Idle, waiting and failed states do not establish recovery")
            }
            try receiveErrorEvent(["type": "state", "sessionID": "recovering", "state": "working", "text": "A new turn started"])
            precondition(recovering.sessionErrors["recovering"] == nil,
                         "Resumed work must retire the previous agent error from both native surfaces. Fixture: \(fixtureRoot.path)")
            precondition(recovering.sessionErrors["other"] == "Synthetic model DNS failure",
                         "Recovery must not dismiss another session's error")
            precondition(recovering.requestErrors["unresolved-reply"] == "Reply delivery remains uncertain",
                         "Resumed work must not hide an unresolved reply failure")
            try receiveErrorEvent(["type": "error", "sessionID": "recovering", "text": "A new model failure"])
            precondition(recovering.sessionErrors["recovering"] == "A new model failure",
                         "A later failure must remain visible")
            try receiveErrorEvent(["type": "activity", "sessionID": "recovering"])
            let localError = recovering.sessionErrors["recovering"]
            precondition(localError == "Agent sent an empty activity event.")
            try receiveErrorEvent(["type": "state", "sessionID": "recovering", "state": "working", "text": "Work resumed"])
            precondition(recovering.sessionErrors["recovering"] == localError,
                         "Agent recovery must preserve local validation failures")
        }
        do {
            let automated = Store(directory: fixtureRoot.appendingPathComponent("automation"), defaults: defaults)
            let client = Process()
            defer { if client.isRunning { client.terminate() }; automated.stop() }
            func waitForAutomation(line: UInt = #line, _ predicate: () -> Bool) {
                let deadline = Date().addingTimeInterval(10)
                while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.025)) }
                precondition(predicate(), "Synthetic automation fixture at \(line) failed: \(automated.error ?? "no error")")
            }
            var ready = false
            automated.server.onReady = { ready = true }
            try automated.server.start()
            waitForAutomation { ready }
            client.executableURL = AgentSetup.findExecutable("node", path: AgentSetup.searchPath)
            client.arguments = ["Tests/UI/automation-fixture.mjs", automated.directory.path]
            var environment = ProcessInfo.processInfo.environment
            environment["NODE_TLS_REJECT_UNAUTHORIZED"] = "1"
            client.environment = environment
            try client.run()
            let id = "automation-fixture"
            waitForAutomation { automated.pending.count == 4 }
            automated.setSessionAutoYes(id, enabled: true)
            precondition(automated.automation.enabled.contains(id), "Fixture must advertise a supported automation capability")
            precondition(automated.pending.count == 4 && automated.sending.isEmpty, "Normal Auto-yes must leave existing prompts alone")
            automated.setSessionDangerousAutoYes(id, enabled: true)
            waitForAutomation { automated.pending.count == 2 && automated.sending.isEmpty }
            precondition(automated.automation.dangerous.contains(id) && automated.automation.enabled.isEmpty)
            precondition(Set(automated.pending.map(\.request.id)) == ["restricted", "manual-question"],
                         "Dangerous mode must preserve questions and ineligible requests")
            func sendEvent(_ value: [String: Any]) throws {
                automated.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: JSONSerialization.data(withJSONObject: value)))
            }
            try sendEvent(["type": "request", "sessionID": id, "request": [
                "id": "future-tool", "kind": "permission", "title": "Future synthetic tool", "detail": "",
                "autoEligible": false, "sessionAutoEligible": true, "questions": []
            ]])
            waitForAutomation { !automated.sending.contains("future-tool") && automated.pending.count == 2 }
            struct AutomatedReply: Decodable { let automatic: Bool; let approvalScope: String }
            let replies = try String(contentsOf: automated.directory.appendingPathComponent("replies.jsonl"), encoding: .utf8)
                .split(separator: "\n").map { try JSONDecoder().decode(AutomatedReply.self, from: Data($0.utf8)) }
            precondition(replies.count == 3 && replies.allSatisfy { $0.automatic && $0.approvalScope == "session" },
                         "Waiting and future tools must use the existing checked automatic approval path")
            precondition(automated.audit.filter { $0.automatic && $0.action.contains("Dangerous Auto-yes") }.count == 3)
            automated.setSessionAutoYes(id, enabled: true)
            precondition(automated.automation.dangerous.isEmpty && automated.automation.enabled.contains(id))
            automated.setSessionDangerousAutoYes(id, enabled: true)
            automated.steer(id, action: "stop")
            precondition(automated.automation.activeIDs.isEmpty, "Stop must disable dangerous mode")
            waitForAutomation { automated.registry.sessions[id]?.stopped == true }
            try sendEvent(["type": "state", "sessionID": id, "state": "working"])
            precondition(automated.registry.sessions[id]?.stopped == false, "New work clears the stopped pose")
            automated.steeringWorkspace.setDraft("Only the helper", sessionID: id, agentID: "worker")
            automated.steer(id, action: "queue", agentID: "worker")
            waitForAutomation { automated.steeringWorkspace.history[id]?.last?.status == "received" }
            automated.steer(id, action: "stop", agentID: "worker")
            waitForAutomation { automated.steeringWorkspace.history[id]?.last?.status == "stopped" }
            precondition(automated.registry.sessions[id]?.stopped == false, "A child stop must not mark the main agent stopped")
            let controlsSent = try String(contentsOf: automated.directory.appendingPathComponent("controls.jsonl"), encoding: .utf8)
                .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
            precondition(controlsSent.count == 3 && controlsSent[1]["agentID"] as? String == "worker" &&
                         controlsSent[1]["text"] as? String == "Only the helper" && controlsSent[2]["agentID"] as? String == "worker",
                         "Native messages and stops must preserve the exact child destination over the real socket")
            automated.steeringWorkspace.setDraft("Keep main conversation draft", sessionID: id)
            let createdID = automated.steer(id, action: "create_subagent",
                creation: SubagentCreation(name: "Review helper", agentType: "general-purpose", prompt: "Check edge cases", model: "fixture-model"))!
            precondition(automated.steer(id, action: "create_subagent",
                creation: SubagentCreation(name: "Duplicate", agentType: "general-purpose", prompt: "Do not send")) == nil,
                "A second Create while delivery is pending must not reach the socket")
            automated.error = nil
            waitForAutomation { automated.steeringWorkspace.receipt(sessionID: id, commandID: createdID)?.status == "created" &&
                automated.registry.sessions[id]?.team?.agents.contains(where: { $0.id == "created-helper" }) == true }
            precondition(automated.steeringWorkspace.draft(sessionID: id) == "Keep main conversation draft")
            let mainRows = AgentChatView(store: automated, session: automated.registry.sessions[id]!, agentID: nil).rows
            precondition(!mainRows.contains {
                if case .command(let receipt) = $0 { return receipt.isManagement }
                return false
            }, "Subagent creation instructions must not masquerade as a message sent to the main agent")
            let removedID = automated.steer(id, action: "remove_subagent", agentID: "created-helper")!
            waitForAutomation { automated.steeringWorkspace.receipt(sessionID: id, commandID: removedID)?.status == "removed" &&
                automated.registry.sessions[id]?.team?.agents.contains(where: { $0.id == "created-helper" }) == false }
            let managementPackets = try String(contentsOf: automated.directory.appendingPathComponent("controls.jsonl"), encoding: .utf8)
                .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
            precondition(managementPackets.count == 5 && managementPackets[3]["action"] as? String == "create_subagent" &&
                managementPackets[3]["agentName"] as? String == "Review helper" &&
                managementPackets[3]["agentType"] as? String == "general-purpose" &&
                managementPackets[3]["model"] as? String == "fixture-model" &&
                managementPackets[3]["text"] as? String == "Check edge cases" && managementPackets[3]["agentID"] == nil &&
                managementPackets[4]["action"] as? String == "remove_subagent" &&
                managementPackets[4]["agentID"] as? String == "created-helper",
                "Creation and removal must preserve their exact fields and targets on the native wire")
            precondition(automated.audit.contains { $0.action.contains("Requested subagent creation") } &&
                automated.audit.contains { $0.action.contains("Requested removal") }, "Management must be audited before dispatch")
            automated.setSessionDangerousAutoYes(id, enabled: true)
            try sendEvent(["type": "error", "sessionID": id, "text": "Synthetic delivery failure"])
            precondition(automated.automation.activeIDs.isEmpty, "Agent errors must disable dangerous mode")
            automated.setSessionDangerousAutoYes(id, enabled: true)
            let history = automated.directory.appendingPathComponent("history.json")
            try FileManager.default.removeItem(at: history)
            try FileManager.default.createDirectory(at: history, withIntermediateDirectories: false)
            precondition(automated.steer(id, action: "create_subagent",
                creation: SubagentCreation(name: "Blocked", agentType: "general-purpose", prompt: "No dispatch")) == nil,
                "A failed creation audit must prevent dispatch")
            precondition(automated.steeringWorkspace.history[id]?.last?.status == "failed")
            let afterAuditFailure = try String(contentsOf: automated.directory.appendingPathComponent("controls.jsonl"), encoding: .utf8)
                .split(separator: "\n").count
            precondition(afterAuditFailure == 5, "Audit failure must not create a runtime helper")
            automated.setSessionDangerousAutoYes(id, enabled: false)
            precondition(automated.automation.activeIDs.isEmpty && automated.error != nil, "Off must work even when its audit cannot be saved")
            automated.setSessionDangerousAutoYes(id, enabled: true)
            precondition(automated.automation.dangerous.isEmpty, "Failed opt-in audit must not enable dangerous mode")
            try FileManager.default.removeItem(at: history)
            automated.setSessionDangerousAutoYes(id, enabled: true)
            let reopened = Store(directory: automated.directory, defaults: defaults)
            precondition(reopened.automation.activeIDs.isEmpty, "Dangerous opt-in must not survive app restart")
            reopened.stop()
            client.terminate()
            waitForAutomation { automated.registry.sessions[id]?.connected == false }
            precondition(automated.automation.activeIDs.isEmpty, "Disconnect must disable dangerous mode")
        }
        if let path = ProcessInfo.processInfo.environment["NOTIFY_MOBILE_RESOURCES"] {
            let phone = Store(directory: fixtureRoot.appendingPathComponent("https-mobile"), defaults: defaults,
                              mobileResources: URL(fileURLWithPath: path))
            let client = Process(), input = Pipe(), output = Pipe(), diagnostics = Pipe()
            defer {
                if client.isRunning { client.terminate() }
                phone.mobile.setEnabled(false); phone.stop()
            }
            func waitForHTTPS(_ predicate: () -> Bool) {
                let deadline = Date().addingTimeInterval(25)
                while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.025)) }
                precondition(predicate(), "Packaged phone integration failed: \(phone.mobile.error ?? phone.error ?? "timed out")")
            }
            var ready = false
            phone.server.onReady = { ready = true }
            try phone.server.start()
            waitForHTTPS { ready }
            phone.mobile.setEnabled(true)
            waitForHTTPS { phone.mobile.status != nil }
            phone.mobile.invite()
            waitForHTTPS { phone.mobile.status?.pairingCode != nil }
            client.executableURL = AgentSetup.findExecutable("node", path: AgentSetup.searchPath)
            client.arguments = ["Tests/UI/mobile-e2e.mjs"]
            client.standardInput = input; client.standardOutput = output; client.standardError = diagnostics
            var environment = ProcessInfo.processInfo.environment
            environment["NODE_TLS_REJECT_UNAUTHORIZED"] = "1"
            client.environment = environment
            try client.run()
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: [
                "directory": phone.directory.path, "url": phone.mobile.status!.url, "code": phone.mobile.status!.pairingCode!
            ]) + Data([10]))
            try input.fileHandleForWriting.close()
            waitForHTTPS { phone.mobile.pairing != nil || !client.isRunning }
            precondition(phone.mobile.pairing?.name == "HTTPS fixture phone", "Only the disposable test phone may be confirmed")
            phone.mobile.confirmPairing(true)
            waitForHTTPS { !client.isRunning }
            let errors = String(decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            precondition(client.terminationStatus == 0, "Real native/HTTPS phone round-trip failed: \(errors)")
            precondition(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("\"ok\":true"))
            print("Packaged HTTPS phone, native Store and agent acknowledgment round-trip passed")
        }
        do {
            let resources = fixtureRoot.appendingPathComponent("mobile-resources")
            let script = resources.appendingPathComponent("mobile/src/main.mjs")
            try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "Tests/UI/mobile-fixture.mjs"), to: script)
            let mobileStore = Store(directory: fixtureRoot.appendingPathComponent("mobile-store"), defaults: defaults, mobileResources: resources)
            defer { mobileStore.mobile.setEnabled(false); mobileStore.stop() }
            func waitFor(line: UInt = #line, _ predicate: () throws -> Bool) rethrows {
                let deadline = Date().addingTimeInterval(10)
                while !(try predicate()) && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.025)) }
                let reached = try predicate()
                precondition(reached, "Native phone fixture at line \(line) failed: \(mobileStore.mobile.error ?? mobileStore.error ?? "no reported error"); \(mobileStore.directory.path)")
            }
            var ready = false
            mobileStore.server.onReady = { ready = true }
            try mobileStore.server.start()
            waitFor { ready }
            mobileStore.mobile.setEnabled(true)
            waitFor { mobileStore.mobile.status != nil && mobileStore.pending.count == 2 }
            mobileStore.mobile.publish()
            let eventsURL = mobileStore.directory.appendingPathComponent("mobile/events.jsonl")
            struct Event: Decodable {
                let type: String
                let id: String?
                let ok: Bool?
                let tls: String?
            }
            func events() throws -> [Event] {
                try String(contentsOf: eventsURL, encoding: .utf8).split(separator: "\n").map {
                    try JSONDecoder().decode(Event.self, from: Data($0.utf8))
                }
            }
            let startupEvents = try events()
            precondition(startupEvents.first?.tls == "1", "Phone helper must not inherit disabled TLS verification")
            mobileStore.mobile.invite()
            waitFor { mobileStore.mobile.pairing != nil }
            precondition(mobileStore.mobile.pairing?.code == "234567", "Mac must show the comparison code before approving pairing")
            mobileStore.mobile.confirmPairing(true)
            mobileStore.mobile.invite()
            waitFor { mobileStore.mobile.pairing != nil }
            mobileStore.mobile.revoke("expire-fixture-comparison")
            waitFor { mobileStore.mobile.pairing == nil }
            mobileStore.mobile.testPush()
            waitFor { mobileStore.sending.contains("custom") }
            try waitFor { try events().contains { $0.type == "agent-reply" } }
            let beforeAck = try events()
            precondition(beforeAck.contains { $0.id == "bad-ticket" && $0.ok == false },
                         "A mismatched phone ticket must be rejected")
            precondition(!beforeAck.contains { $0.id == "custom-reply" && $0.type == "result" },
                         "A socket write must not be reported as an acknowledged phone reply")
            precondition(beforeAck.filter { $0.type == "agent-reply" }.count == 1,
                         "Only a valid custom answer should reach the agent")
            mobileStore.mobile.testPush()
            waitFor { !mobileStore.sending.contains("custom") && mobileStore.pending.count == 1 }
            try waitFor { try events().contains { $0.id == "custom-reply" } }
            let afterAck = try events()
            precondition(afterAck.contains { $0.id == "custom-reply" && $0.ok == true },
                         "The phone must receive success only after matching runtime acknowledgment")
            mobileStore.mobile.testPush()
            try waitFor { try events().contains { $0.id == "fixed-reply" } }
            let fixedEvents = try events()
            precondition(fixedEvents.contains { $0.id == "fixed-reply" && $0.ok == false },
                         "Phone custom answers must not bypass a fixed-choice agent request")
            precondition(fixedEvents.filter { $0.type == "agent-reply" }.count == 1)
            mobileStore.mobile.testPush()
            try waitFor { try events().contains { $0.id == "mismatched-answer" } }
            let mismatchEvents = try events()
            precondition(mismatchEvents.contains { $0.id == "mismatched-answer" && $0.ok == false },
                         "A different terminal answer must not acknowledge the phone's answer")
        }
        do {
            let welcomeDefaults = UserDefaults(suiteName: suite + "-welcome")!
            defer { welcomeDefaults.removePersistentDomain(forName: suite + "-welcome") }
            let background = Store(directory: fixtureRoot.appendingPathComponent("first-use"), defaults: welcomeDefaults)
            precondition(!background.setupVisible, "Constructing a Store must never open welcome during background startup")
            try FileManager.default.createDirectory(at: background.directory, withIntermediateDirectories: true)
            let first = Store(directory: background.directory, defaults: welcomeDefaults)
            first.offerWelcome()
            precondition(first.setupVisible, "First explicit opening must offer setup even after a background-only restart")
            first.setupVisible = false
            first.offerWelcome()
            precondition(!first.setupVisible, "Dismissed welcome must not reopen")
            let reopened = Store(directory: fixtureRoot.appendingPathComponent("first-use"), defaults: welcomeDefaults)
            reopened.offerWelcome()
            precondition(!reopened.setupVisible, "Welcome dismissal must persist across restarts")
            welcomeDefaults.removeObject(forKey: "hasSeenWelcome")
            let existing = fixtureRoot.appendingPathComponent("existing-user")
            try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
            let upgraded = Store(directory: existing, defaults: welcomeDefaults)
            upgraded.offerWelcome()
            precondition(!upgraded.setupVisible, "Existing users must not be forced through welcome after clean shutdown removes discovery")
            background.stop(); first.stop(); reopened.stop(); upgraded.stop()
        }
        precondition(reorderedSessionIDs(["a", "b", "c"], moving: "a", over: "c") == ["b", "c", "a"],
                     "Dragging down must place a session at the target position")
        precondition(reorderedSessionIDs(["a", "b", "c"], moving: "c", over: "a") == ["c", "a", "b"],
                     "Dragging up must preserve the other sessions' relative order")
        precondition(reorderedSessionIDs(["a", "b"], moving: "external", over: "b") == nil,
                     "Unrelated text drops must not mutate session order")
        do {
            let orderingStore = Store(directory: fixtureRoot.appendingPathComponent("ordering"), defaults: defaults)
            defer { orderingStore.stop(); defaults.removeObject(forKey: "sessionOrder") }
            let savedOrderIDs = ["00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002"]
            for (index, id) in ["first", "second"].enumerated() {
                for packet: [String: Any] in [
                    ["type": "hello", "sessionID": id, "agent": "copilot", "cwd": "/fixture"],
                    ["type": "metadata", "sessionID": id, "title": id, "sourceSessionID": savedOrderIDs[index]]
                ] {
                    orderingStore.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: JSONSerialization.data(withJSONObject: packet)))
                }
            }
            orderingStore.rememberSessionOrder(["second", "first"])
            let reopened = Store(directory: fixtureRoot.appendingPathComponent("ordering"), defaults: defaults)
            defer { reopened.stop() }
            precondition(reopened.sessionOrder == Array(savedOrderIDs.reversed()),
                         "Manual order must persist under canonical chat identities, not transient connections")
        }
        defer {
            store.stop()
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: fixtureRoot) }
            catch { preconditionFailure("Could not clean up UI fixture: \(error)") }
        }
        var session = SessionRecord(id: "ui-fixture", agent: "copilot", cwd: "/example")
        session.title = "Readable session title"
        let longTitle = (1...45).map { "Paragraph \($0): this long question must remain readable when you scroll." }.joined(separator: "\n\n")
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "long-question", "kind": "question", "title": longTitle, "detail": "", "autoEligible": false,
            "questions": [["id": "choice", "text": "The final question", "multiple": false, "allowFreeform": false,
                           "options": [["label": "Yes", "description": "Finish this request"]]]]
        ])
        let request = try JSONDecoder().decode(AgentRequest.self, from: data)
        var presenceSession = session
        precondition(AgentPresence(session: presenceSession) == .resting, "Idle alone is not a completion claim")
        presenceSession.baseState = "working"
        let reasoningData = try JSONSerialization.data(withJSONObject: [
            "id": "presence-reason", "kind": "reasoning", "title": "Published reasoning", "detail": "Fixture",
            "status": "running", "timestamp": "2026-11-14T18:00:00Z"
        ])
        try presenceSession.activity.receive(JSONDecoder().decode(ActivityEntry.self, from: reasoningData))
        precondition(AgentPresence(session: presenceSession) == .thinking, "Thinking requires actual running reasoning")
        presenceSession.requests = [request]
        precondition(AgentPresence(session: presenceSession) == .waiting, "A decision must override prior thinking")
        presenceSession.connected = false
        precondition(AgentPresence(session: presenceSession) == .disconnected, "Disconnected agents must not appear actively waiting or thinking")
        presenceSession.connected = true
        presenceSession.requests = []
        presenceSession.baseState = "ready"
        precondition(AgentPresence(session: presenceSession) == .resting, "Idle must stop a stale reasoning animation")
        let presenceResponseData = try JSONSerialization.data(withJSONObject: [
            "id": "presence-response", "kind": "assistant", "title": "Agent response", "detail": "Fixture reply",
            "status": "complete", "timestamp": "2026-11-14T18:01:00Z"
        ])
        try presenceSession.activity.receive(JSONDecoder().decode(ActivityEntry.self, from: presenceResponseData))
        precondition(AgentPresence(session: presenceSession) == .finished, "A completed main response plus idle may show response finished")
        presenceSession.baseState = "working"
        precondition(AgentPresence(session: presenceSession) == .working, "An old finished response must not label new work as done")
        presenceSession.baseState = "unrecognized"
        precondition(!AgentPresence(session: presenceSession).animates(visible: true, reduceMotion: false),
                     "Unknown runtime states must not invent working activity")
        precondition(!AgentPresence.working.animates(visible: false, reduceMotion: false) &&
                     !AgentPresence.thinking.animates(visible: true, reduceMotion: true) &&
                     AgentPresence.resting.animates(visible: true, reduceMotion: false) &&
                     AgentPresence.working.animates(visible: true, reduceMotion: false),
                     "Visible active and idle poses may animate, respecting Reduce Motion")
        presenceSession.stopped = true
        precondition(AgentPresence(session: presenceSession) == .stopped, "An acknowledged Stop needs a distinct resting pose")
        precondition(!AgentPresence.stopped.animates(visible: true, reduceMotion: false))
        let typing = AgentPose(presence: .working, time: 0.25)
        precondition(typing.leftHand != typing.rightHand, "Typing must alternate hands")
        precondition(AgentPose(presence: .resting, time: 0).blinking &&
                     !AgentPose(presence: .resting, time: 1).blinking, "Idle blinks must be brief, not constantly closed eyes")
        precondition(AgentPose(presence: .stopped, time: 0) == AgentPose(presence: .stopped, time: 1),
                     "Stopped must not keep typing or blinking")
        let host = NSHostingView(rootView: RequestEditor(store: store, session: session, request: request)
            .padding(20).background(Palette.surface).preferredColorScheme(.light))
        let window = ReplyPanel(contentRect: NSRect(x: 0, y: 0, width: 410, height: 430),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 410, height: 430)
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func pumpNativeEvents() {
            for _ in 0..<100 {
                guard let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) else { break }
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
        }
        func enterSearch(_ query: String, in view: NSView) {
            guard let field = descendants(view).compactMap({ $0 as? NSTextField }).first(where: {
                $0.placeholderString == "Search sessions"
            }) else { preconditionFailure("Session search must remain a native editable field") }
            field.stringValue = query
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
        do {
            let selectionStore = Store(directory: fixtureRoot.appendingPathComponent("selection"), defaults: defaults)
            defer { selectionStore.stop() }
            func receiveSelection(_ packet: [String: Any]) throws {
                selectionStore.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: JSONSerialization.data(withJSONObject: packet)))
            }
            try receiveSelection(["type": "hello", "sessionID": session.id, "agent": "copilot", "cwd": "/example"])
            try receiveSelection(["type": "request", "sessionID": session.id, "request": try JSONSerialization.jsonObject(with: data)])
            try receiveSelection(["type": "hello", "sessionID": "unconnected", "agent": "copilot", "cwd": "/other"])
            selectionStore.server.onDisconnect("unconnected")
            selectionStore.select("unconnected", request: "stale")
            selectionStore.waitingOnly = true
            let selectionHost = NSHostingView(rootView: DashboardView(store: selectionStore))
            let selectionWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
                                           styleMask: [.borderless], backing: .buffered, defer: false)
            selectionWindow.isReleasedWhenClosed = false
            selectionWindow.contentView = selectionHost
            func settleSelection() {
                for _ in 0..<10 {
                    selectionHost.layoutSubtreeIfNeeded()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                }
            }
            settleSelection()
            precondition(selectionStore.selectedID == session.id && selectionStore.selectedRequestID == nil,
                         "Filtering must select a visible waiting session, not retain an unrelated disconnected detail")
            selectionStore.server.onDisconnect(session.id)
            settleSelection()
            precondition(selectionStore.selectedID == nil && selectionStore.selectedRequestID == nil,
                         "No matching connected requests must clear actionable session details")
            selectionStore.waitingOnly = false
            settleSelection()
            try receiveSelection(["type": "hello", "sessionID": "automatic-session", "agent": "copilot", "cwd": "/automatic"])
            settleSelection()
            precondition(selectionStore.selectedID == "automatic-session",
                         "An automatic setup selection must yield when connected work becomes available")
            selectionStore.select("unconnected")
            try receiveSelection(["type": "hello", "sessionID": "new-session", "agent": "copilot", "cwd": "/new"])
            settleSelection()
            precondition(selectionStore.selectedID == "unconnected", "A new session must not steal an explicit visible selection")
            enterSearch("no-such-session", in: selectionHost)
            settleSelection()
            precondition(selectionStore.selectedID == nil, "Search with no matches must not leave unrelated decisions actionable")
            selectionStore.select("new-session")
            settleSelection()
            precondition(selectionStore.selectedID == "new-session",
                         "Opening a session from a notification must reveal it through active search filters")
            selectionWindow.contentView = nil
        }
        let scrolls = descendants(host).compactMap { $0 as? NSScrollView }
        guard let scroll = scrolls.first, let document = scroll.documentView else {
            preconditionFailure("Long questions need a native scroll view")
        }
        precondition(document.frame.height > scroll.contentSize.height * 3, "Full prompt must be inside the scrollable document, not truncated")
        precondition(scroll.frame.height < host.bounds.height - 70, "Reply actions must retain space outside the scroll body")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.frame.maxY - scroll.contentSize.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        precondition(scroll.contentView.bounds.minY > 0, "The full prompt must actually scroll")
        let hello = try JSONSerialization.data(withJSONObject: ["type": "hello", "sessionID": session.id, "agent": "copilot", "cwd": session.cwd])
        store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: hello))
        let packet = try JSONSerialization.data(withJSONObject: [
            "type": "request", "sessionID": session.id, "request": try JSONSerialization.jsonObject(with: data)
        ])
        store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: packet))
        store.sending.insert(request.id)
        precondition(store.floatingRequests.contains(where: { $0.request.id == request.id }),
                     "Sending a reply must keep its card visible until acknowledgment")
        store.automaticallySending.insert(request.id)
        precondition(!store.floatingRequests.contains(where: { $0.request.id == request.id }),
                     "Automatic approvals must not flash a card requiring no user action")
        store.automaticallySending.remove(request.id)
        store.sending.remove(request.id)
        store.setColor(0xAABBCC, for: session)
        precondition(store.appearance.color(for: session) == 0xAABBCC, "Native picker updates this session")
        let scopedError = try JSONSerialization.data(withJSONObject: [
            "type": "error", "sessionID": session.id, "requestID": request.id, "text": "Synthetic delivery error"
        ])
        store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: scopedError))
        precondition(store.requestErrors[request.id] == "Synthetic delivery error" && store.error == nil,
                     "Reply errors belong to their request, not a blocking global alert")
        store.attentionIDs.removeAll()
        store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: packet))
        precondition(store.attentionIDs.isEmpty, "Replayed pending requests cannot create duplicate alerts")
        let activityData = try JSONSerialization.data(withJSONObject: [
            "type": "activity", "sessionID": session.id,
            "activity": ["id": "tool-event", "kind": "tool", "title": "Run test", "detail": "Synthetic output",
                         "status": "running", "timestamp": "2026-11-13T20:00:00Z"]
        ])
        store.select(session.id, request: request.id)
        store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: activityData))
        precondition(store.selectedID == session.id && store.registry.sessions[session.id]?.activity.entries.count == 1,
                     "Activity must reach the selected chat without changing selection")
        let responseData = try JSONSerialization.data(withJSONObject: [
            "type": "activity", "sessionID": session.id,
            "activity": ["id": "response-event", "kind": "assistant", "title": "Agent response", "detail": "Completed response",
                         "status": "complete", "timestamp": "2026-11-13T20:00:00Z"]
        ])
        for _ in 0..<2 { store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: responseData)) }
        precondition(store.registry.sessions[session.id]?.output == "Completed response\n\n",
                     "Coalesced activity must populate notification context without duplicating replayed text")
        let floating = NSHostingView(rootView: FloatingView(store: store, openCenter: {}))
        window.contentView = floating
        floating.frame = NSRect(x: 0, y: 0, width: 410, height: 550)
        for _ in 0..<10 {
            floating.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        guard let floatingScroll = descendants(floating).compactMap({ $0 as? NSScrollView }).first,
              let floatingDocument = floatingScroll.documentView else { preconditionFailure("Floating cards must retain scrolling") }
        precondition(floatingDocument.frame.height > floatingScroll.contentSize.height * 3, "Floating cards must keep the complete prompt")
        precondition(floatingScroll.frame.height < floating.bounds.height - 100, "Floating reply controls must remain outside the scrolling content")
        func snapshot(_ color: UInt32) -> NSBitmapImageRep {
            store.setColor(color, for: session)
            for _ in 0..<10 {
                floating.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            let bitmap = floating.bitmapImageRepForCachingDisplay(in: floating.bounds)!
            floating.cacheDisplay(in: floating.bounds, to: bitmap)
            return bitmap
        }
        let redCard = snapshot(0xEF4444), blueCard = snapshot(0x4488FF)
        store.setColor(0xF29A78, for: session)
        func luminance(_ color: NSColor) -> Double {
            func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
        }
        func resolved(_ color: Color, appearance: NSAppearance.Name) -> NSColor {
            var result: NSColor?
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                result = NSColor(color).usingColorSpace(.sRGB)
            }
            return result!
        }
        func contrast(_ foreground: NSColor, _ background: NSColor) -> Double {
            let a = luminance(foreground), b = luminance(background)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
        precondition(luminance(resolved(Palette.surface, appearance: .darkAqua)) < 0.15,
                     "Dark macOS appearance must produce a genuinely dark workspace")
        let lightSurface = resolved(Palette.surface, appearance: .aqua)
        precondition(lightSurface.redComponent > lightSurface.blueComponent + 0.035,
                     "Light mode must use warm beige rather than stark white")
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            for background in [Palette.surface, Palette.sidebar, Palette.raised] {
                for foreground in [Palette.ink, Palette.muted] {
                    precondition(contrast(resolved(foreground, appearance: appearance), resolved(background, appearance: appearance)) >= 4.5,
                                 "Workspace text must remain readable in both appearances")
                }
            }
            precondition(contrast(resolved(Palette.highlightInk, appearance: appearance), resolved(Palette.accent, appearance: appearance)) >= 4.5,
                         "Highlighted actions must remain readable in both appearances")
            for color: UInt32 in [0xFFFFFF, 0xFFFF00, 0x00FF00, 0xF29A78, 0x408ED8, 0]
                + store.appearance.suggestedColors(for: session, among: []) {
                store.setColor(color, for: session)
                let surface = resolved(store.sessionSurface(session), appearance: appearance)
                for foreground in [Palette.ink, Palette.noticeMuted, Palette.amber, Palette.error, Palette.diffAdded, Palette.diffRemoved] {
                    precondition(contrast(resolved(foreground, appearance: appearance), surface) >= 4.5,
                                 "Every session tint must preserve text and warning contrast in both appearances")
                }
                for foreground in [Palette.line, Palette.accent] {
                    precondition(contrast(resolved(foreground, appearance: appearance), surface) >= 3,
                                 "Control outlines and keyboard focus must remain visible over session tints")
                }
                precondition(appearance == .aqua ? luminance(surface) > 0.6 : luminance(surface) < 0.15,
                             "Session color must not overpower the system appearance")
            }
        }
        var changedInteriorPixels = 0
        for x in stride(from: redCard.pixelsWide / 5, to: redCard.pixelsWide * 4 / 5, by: 4) {
            for y in stride(from: 20, to: redCard.pixelsHigh - 20, by: 4) {
                let red = redCard.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                let blue = blueCard.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                if abs(red.redComponent - blue.redComponent) > 0.05 || abs(red.blueComponent - blue.blueComponent) > 0.05 {
                    changedInteriorPixels += 1
                }
            }
        }
        precondition(changedInteriorPixels > 200, "Session color must tint the notification header, not only a thin edge or dot")
        print("Native editor and floating-card long-question scrolling checks passed")
        let capabilities = try JSONSerialization.data(withJSONObject: [
            "type": "capabilities", "sessionID": session.id, "steering": true, "sessionAutoYes": true
        ])
        store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: capabilities))
        precondition(store.automation.enabled.isEmpty, "Capability negotiation must not enable Auto-yes")
        store.setSessionAutoYes(session.id, enabled: true)
        precondition(store.automation.enabled.contains(session.id), "Explicit Auto-yes must be available on a capable session")
        store.steeringWorkspace.drafts[session.id] = "Use the smallest compatible change"
        store.showSteering(session.id)
        for _ in 0..<10 {
            floating.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(store.steeringSessionID == session.id, "The floating composer must target the selected session")
        precondition(!descendants(floating).compactMap({ $0 as? NSScrollView }).isEmpty, "Composer activity and warnings must leave scrollable space")
        let history = fixtureRoot.appendingPathComponent("history.json")
        try FileManager.default.removeItem(at: history)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: false)
        let broadRequest = try JSONSerialization.data(withJSONObject: [
            "type": "request", "sessionID": session.id,
            "request": ["id": "broad-test", "kind": "permission", "title": "Allow shell?", "detail": "Synthetic fixture",
                        "autoEligible": false, "sessionAutoEligible": true, "questions": []]
        ])
        store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: broadRequest))
        precondition(store.automation.enabled.isEmpty, "Failed audit writes must disable broad Auto-yes")
        precondition(store.registry.sessions[session.id]?.requests.contains(where: { $0.id == "broad-test" }) == true,
                     "Failed audit writes must leave the permission unanswered")
        let scopedRequestData = try JSONSerialization.data(withJSONObject: [
            "id": "scope-test", "kind": "permission", "title": "Allow shell?", "detail": String(repeating: "A long readable command.\n", count: 120),
            "autoEligible": false, "questions": [],
            "permissionOptions": [["id": "session", "label": "Allow every time in this session", "detail": "Only npm test in this session."]]
        ])
        let scopedRequest = try JSONDecoder().decode(AgentRequest.self, from: scopedRequestData)
        let scopedPacket = try JSONSerialization.data(withJSONObject: [
            "type": "request", "sessionID": session.id, "request": try JSONSerialization.jsonObject(with: scopedRequestData)
        ])
        store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: scopedPacket))
        store.reply(session: session.id, request: scopedRequest, decision: "allow", permissionOptionID: "session")
        precondition(store.requestErrors[scopedRequest.id]?.hasPrefix("No approval sent:") == true && !store.sending.contains(scopedRequest.id),
                     "Remembered approvals must not dispatch if the scope cannot be audited")
        let scopeHost = NSHostingView(rootView: RequestEditor(store: store, session: session, request: scopedRequest).padding(20))
        window.contentView = scopeHost
        scopeHost.frame = NSRect(x: 0, y: 0, width: 410, height: 430)
        for _ in 0..<10 {
            scopeHost.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let menuButtons = descendants(scopeHost).compactMap { $0 as? NSPopUpButton }
        precondition(!menuButtons.contains(where: { $0.title == "Allow every time / other scopes" }),
                     "Approval scopes must be direct buttons, never buried in a menu")
        let scopeScroll = descendants(scopeHost).compactMap { $0 as? NSScrollView }.first!
        precondition(scopeScroll.frame.height < scopeHost.bounds.height - 100, "Additional scopes must not push the fixed approval controls outside the card")
        window.contentView = floating
        try FileManager.default.removeItem(at: history)
        let scopedCompletion = try JSONSerialization.data(withJSONObject: [
            "type": "resolved", "sessionID": session.id, "requestID": scopedRequest.id, "decision": "allow", "permissionOptionID": "session"
        ])
        store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: scopedCompletion))
        precondition(store.audit.first?.action.contains("Only npm test in this session.") == true,
                     "Accepted scopes must be preserved in approval history, not reduced to generic allow")
        store.setSessionAutoYes(session.id, enabled: true)
        store.server.onDisconnect(session.id)
        precondition(store.automation.enabled.isEmpty, "Disconnect must clear the session's Auto-yes opt-in")
        store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: hello))
        precondition(store.registry.sessions[session.id]?.canSteer == false, "Reconnect must renegotiate controls")
        precondition(store.steeringWorkspace.drafts[session.id] == "Use the smallest compatible change", "Switching/disconnection must preserve drafts")
        store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: capabilities))
        store.setSessionAutoYes(session.id, enabled: true)
        let uncertainID = try store.steeringWorkspace.begin(session: store.registry.sessions[session.id]!, action: "interrupt")
        let uncertain = try JSONSerialization.data(withJSONObject: [
            "type": "control_status", "sessionID": session.id, "commandID": uncertainID, "status": "unknown", "text": "Interrupt delivery failed"
        ])
        store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: uncertain))
        precondition(store.automation.enabled.isEmpty, "Uncertain steering must disable Auto-yes so the unredirected task cannot keep receiving approvals")
        print("Native composer, audit-failure and session Auto-yes reset checks passed")
        store.error = nil
        for type in ["reply", "resolved"] {
            store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: packet))
            store.sending.insert(request.id)
            let completion = try JSONSerialization.data(withJSONObject: [
                "type": type, "sessionID": session.id, "requestID": request.id, "decision": "deny"
            ])
            store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: completion))
            precondition(store.error == nil, "Completion from current or already-running bridges must not trigger an unsupported-event alert")
            precondition(store.registry.sessions[session.id]?.requests.contains(where: { $0.id == request.id }) == false,
                         "Acknowledged requests must leave the notification queue")
            precondition(!store.sending.contains(request.id), "Acknowledged replies must clear sending state")
        }
        print("Native current and legacy completion checks passed")
        let dashboard = NSHostingView(rootView: DashboardView(store: store))
        window.contentView = dashboard
        dashboard.frame = NSRect(x: 0, y: 0, width: 1120, height: 750)
        for _ in 0..<10 {
            dashboard.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let workspaceBitmap = dashboard.bitmapImageRepForCachingDisplay(in: dashboard.bounds)!
        dashboard.cacheDisplay(in: dashboard.bounds, to: workspaceBitmap)
        let workspaceText = VNRecognizeTextRequest()
        workspaceText.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: workspaceBitmap.cgImage!, options: [:]).perform([workspaceText])
        let workspaceLabels = (workspaceText.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        precondition(workspaceLabels.contains("Chat") && !workspaceLabels.contains("Controls"),
                     "Messaging must have one Chat destination, not a duplicate Controls tab")
        precondition(workspaceLabels.contains("Hierarchy"), "The agent hierarchy must be discoverable in session navigation")
        func showActivity(in view: NSView) {
            guard let tabs = descendants(view).compactMap({ $0 as? NSSegmentedControl }).first(where: {
                $0.segmentCount == 4 && $0.label(forSegment: 2) == "Settings"
            }) else { preconditionFailure("Session navigation must expose recognizable native tabs") }
            tabs.selectedSegment = 2
            precondition(tabs.sendAction(tabs.action, to: tabs.target), "Settings must retain session automation without hiding live activity")
            for _ in 0..<10 {
                view.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
        }
        showActivity(in: dashboard)
        precondition(descendants(dashboard).compactMap { $0 as? NSScrollView }.count >= 2,
                     "Session list and selected activity need independent scroll regions")
        print("Native workspace layout, activity selection and notification replay checks passed")
        if let argument = CommandLine.arguments.firstIndex(of: "--capture"), CommandLine.arguments.indices.contains(argument + 1) {
            let output = URL(fileURLWithPath: CommandLine.arguments[argument + 1], isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let visual = Store(directory: fixtureRoot.appendingPathComponent("visual"), defaults: defaults)
            try FileManager.default.createDirectory(at: visual.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            visual.autoYes = false
            func receive(_ packet: [String: Any]) throws {
                visual.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: JSONSerialization.data(withJSONObject: packet)))
            }
            let tasks = ["Fix token refresh", "Review invoice totals", "Keyboard navigation", "Trace upload failures",
                         "Update search tests", "Document webhook retries", "Clean up redirects", "Cache invalidation"]
            let projects = ["accounts", "billing", "web", "api", "web", "api", "web", "api"]
            for (index, title) in tasks.enumerated() {
                let id = "visual-\(index)"
                try receive(["type": "hello", "sessionID": id, "agent": index == 1 ? "claude" : "copilot", "cwd": "/Projects/\(projects[index])"])
                try receive(["type": "metadata", "sessionID": id, "title": title])
                try receive(["type": "capabilities", "sessionID": id, "activityFeed": true, "steering": true, "sessionAutoYes": true,
                             "subagentChat": true, "subagentStop": true,
                             "subagentCreate": true, "subagentRemove": true, "subagentTypes": ["general-purpose", "explore"],
                             "subagentModels": ["account-model"]])
                try receive(["type": "state", "sessionID": id, "state": index > 5 ? "ready" : "working", "text": index > 5 ? "Agent idle" : "Reviewing the requested changes"])
                try receive(["type": "activity", "sessionID": id, "activity": [
                    "id": "tool-\(index)", "kind": "tool", "title": index == 0 ? "Read auth/refresh.ts" : "Inspect project files",
                    "detail": "Read the relevant implementation before making changes.", "status": "complete",
                    "timestamp": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-95))
                ]])
                try receive(["type": "activity", "sessionID": id, "activity": [
                    "id": "reply-\(index)", "kind": "assistant", "title": "Agent response",
                    "detail": index == 0 ? "I found the expired-token path. The change is ready for a focused check." :
                        "I am checking the implementation and its edge cases before making changes.",
                    "status": "complete", "timestamp": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-90))
                ]])
                if index != 1 {
                    let helpers: [[String: Any]] = index == 0 || index == 2 ? [
                        ["id": "worker-one", "name": "Code explorer", "task": "Trace focus order through the overflow menu", "status": "running", "model": "Claude Sonnet"],
                        ["id": "worker-two", "name": "Test runner", "task": "Exercise keyboard navigation and dismissal", "status": "running"],
                        ["id": "worker-three", "name": "Reviewer", "task": "Review the proposed keyboard changes", "status": "idle"]
                    ] : []
                    try receive(["type": "team", "sessionID": id, "team": [
                        "agents": helpers, "runningCount": helpers.isEmpty ? 0 : 2,
                        "idleCount": helpers.isEmpty ? 0 : 1, "truncated": false
                    ]])
                    try receive(["type": "activity", "sessionID": id, "activity": [
                        "id": "child-tool", "agentID": "worker-one", "kind": "tool", "title": "Reading menu.tsx",
                        "detail": "PRIVATE CHILD TOOL DETAIL", "status": "running",
                        "timestamp": ISO8601DateFormatter().string(from: Date())
                    ]])
                }
            }
            let choices = [
                ["id": "session", "label": "Allow every time in this session", "detail": "Command pattern: npm test. Applies to this running session; resume may ask again."],
                ["id": "project", "label": "Always allow in this project", "detail": "Command pattern: npm test. Applies to future sessions in /Projects/accounts."]
            ]
            let detail = String(data: try JSONSerialization.data(withJSONObject: [
                "fullCommandText": "npm test -- auth/refresh.test.ts",
                "intention": "Check refreshed-token behavior before continuing.",
                "canOfferSessionApproval": true
            ]), encoding: .utf8)!
            try receive(["type": "request", "sessionID": "visual-0", "request": [
                "id": "visual-request", "kind": "permission", "title": "Run authentication tests?",
                "detail": detail, "questions": [], "autoEligible": false, "permissionOptions": choices, "supportsFeedback": true
            ]])
            try receive(["type": "request", "sessionID": "visual-1", "request": [
                "id": "visual-question", "kind": "question", "title": "Which rounding rule should invoices use?",
                "detail": "", "questions": [["id": "0", "text": "Rounding rule", "multiple": false, "allowFreeform": true,
                    "options": [["label": "Per line", "description": "Round each line before adding"], ["label": "Invoice total", "description": "Round after adding all lines"]]]],
                "autoEligible": false
            ]])
            visual.select("visual-0", request: "visual-request")
            visual.replyWorkspace.update(requestIDs: ["visual-request", "visual-question"])
            visual.setColor(0xF29A78, for: visual.selected!)
            let copyExamples = [
                ("Copy response", "## Full response\n\n```swift\nlet value = 42\n```\n"),
                ("Copy message", "Keep this exact message.\nSecond line."),
                ("Copy summary", String(repeating: "A complete summary sentence. ", count: 45).trimmingCharacters(in: .whitespaces))
            ]
            var hierarchySelection: String? = "unchanged"
            func capture<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String,
                                  appearance: NSAppearance.Name = .aqua) throws {
                if name.hasPrefix("settings") { visual.appearanceMode = appearance == .darkAqua ? .dark : .light }
                let capture = NSHostingView(rootView: view)
                capture.sizingOptions = []
                window.appearance = NSAppearance(named: appearance)
                window.contentView = capture
                capture.frame = NSRect(x: 0, y: 0, width: width, height: height)
                window.setContentSize(NSSize(width: width, height: height))
                for _ in 0..<12 {
                    capture.layoutSubtreeIfNeeded()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.025))
                }
                if name.hasPrefix("control-center-activity") { showActivity(in: capture) }
                if name == "control-center-no-results.png" {
                    enterSearch("missing-project", in: capture)
                    for _ in 0..<10 {
                        capture.layoutSubtreeIfNeeded()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                    }
                    precondition(visual.selectedID == nil, "No-results captures must not show an unrelated session")
                }
                precondition(capture.bounds.size == NSSize(width: width, height: height), "Capture must match its requested shipping size")
                if name == "floating-diff.png" {
                    let scroll = descendants(capture).compactMap { $0 as? NSScrollView }.first!
                    precondition(scroll.contentSize.height > 300, "Expanded diffs must use available space, not collapse to a tiny scroll strip")
                }
                if name == "floating-custom-focus.png" {
                    let item = visual.activeFloatingRequest!
                    visual.replyWorkspace.highlighted[item.request.id] = .input("choice")
                    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.025)) }
                    window.makeKey()
                    window.makeFirstResponder(nil)
                    let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                                 isARepeat: false, keyCode: 36)!
                    precondition(window.performKeyEquivalent(with: enter), "The custom-answer action must activate from the focused notification")
                    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.025)) }
                    guard let field = descendants(capture).compactMap({ $0 as? NSTextField }).first(where: {
                        $0.placeholderString == "Type your own answer"
                    }), let editor = field.currentEditor() as? NSTextView, window.firstResponder === editor else {
                        preconditionFailure("Writing a custom answer must focus its real native text editor")
                    }
                    precondition(field.visibleRect.height > 20, "The custom-answer action must reveal the editor below a long choice list")
                    precondition(visual.replyWorkspace.drafts[item.request.id]?.selections["choice"] == ["Strategy 1"],
                                 "Focusing the editor must not discard an existing draft")
                    editor.insertText("Keep the existing schema for now.", replacementRange: NSRange(location: 0, length: 0))
                    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.025)) }
                    precondition(visual.replyWorkspace.drafts[item.request.id]?.answers(for: item.request)["choice"] == ["Keep the existing schema for now."],
                                 "Typing a custom answer must replace a single selected option in the actual reply draft")
                    precondition(!visual.sending.contains(item.request.id), "Opening or typing a custom answer must not send it")
                }
                let bitmap = capture.bitmapImageRepForCachingDisplay(in: capture.bounds)!
                capture.cacheDisplay(in: capture.bounds, to: bitmap)
                if appearance == .darkAqua {
                    let background = bitmap.colorAt(x: bitmap.pixelsWide - 16, y: bitmap.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
                    precondition(luminance(background) < 0.15, "Dark native windows must not contain a forced-light SwiftUI surface: \(name)")
                }
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
                if name.hasPrefix("phone-pairing-") {
                    let recognition = VNDetectBarcodesRequest()
                    recognition.symbologies = [.qr]
                    try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([recognition])
                    precondition(recognition.results?.contains { $0.payloadStringValue == "http://fixture.local:9444" } == true,
                                 "The phone setup QR must remain scannable in both appearances: \(name)")
                }
                if name == "session-automation.png" {
                    let recognition = VNRecognizeTextRequest()
                    recognition.recognitionLevel = .accurate
                    try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([recognition])
                    let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
                    precondition(text.contains("dangerous"), "Dangerous Auto-yes must be a separate visible per-session control")
                }
                if name.contains("dangerous") {
                    let recognition = VNRecognizeTextRequest()
                    recognition.recognitionLevel = .accurate
                    try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([recognition])
                    let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
                    precondition(text.contains("dangerous") && text.contains("turn off"),
                                 "Dangerous mode needs a persistent warning and visible Off action: \(name)")
                }
                if name == "settings.png" {
                    let recognition = VNRecognizeTextRequest()
                    recognition.recognitionLevel = .accurate
                    try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([recognition])
                    let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                    precondition(text.contains("Phone connections") && text.contains("Allow phone connections"),
                                 "Native Settings must expose mobile connection status and an explicit enable control")
                }
                if name.hasPrefix("floating-custom-") {
                    let recognition = VNRecognizeTextRequest()
                    recognition.recognitionLevel = .accurate
                    try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([recognition])
                    let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                    precondition(text.contains("Send answer"), "Custom-answer access must not push Send answer offscreen")
                    precondition(name == "floating-custom-fixed.png" ? text.contains("only accepts the listed choices") :
                                    text.contains("Write your own answer"),
                                 "A custom-answer action or honest fixed-choice limitation must stay visible below long choices")
                }
                if name == "control-center-empty.png" {
                    let recognition = VNRecognizeTextRequest()
                    recognition.recognitionLevel = .accurate
                    try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([recognition])
                    let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                    precondition(text.contains("Connect agents"),
                                 "First-use control center must provide a discoverable agent connection action")
                }
                if name == "welcome-claude-after-error.png" || name == "welcome-install-error.png" {
                    let recognition = VNRecognizeTextRequest()
                    recognition.recognitionLevel = .accurate
                    try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([recognition])
                    let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                    precondition(name == "welcome-install-error.png" ? text.contains("refused") : !text.contains("refused"),
                                 "A Copilot installation failure must remain under Copilot, including when it arrives after switching agents")
                }
                if name == "floating-uri.png" || name == "floating-uri-dark.png" {
                    let recognition = VNRecognizeTextRequest()
                    recognition.recognitionLevel = .accurate
                    try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([recognition])
                    let observations = recognition.results ?? []
                    let target = observations.first { $0.topCandidates(1).first?.string.contains("example.org") == true }
                    let action = observations.first { $0.topCandidates(1).first?.string.contains("Allow once") == true }
                    precondition(target != nil && action != nil && target!.boundingBox.height > action!.boundingBox.height * 1.35,
                                 "The actual URI must be visibly larger than action labels without hiding approval controls")
                    let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                    precondition(!text.contains("Transport bookkeeper") && text.contains("Request details"),
                                 "Technical tool metadata must be available behind disclosure, not compete with the URI")
                }
                if name == "floating-uri-long.png" || name == "floating-uri-long-dark.png" {
                    let recognition = VNRecognizeTextRequest()
                    recognition.recognitionLevel = .accurate
                    try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([recognition])
                    let observations = recognition.results ?? []
                    let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                    let warning = observations.first { $0.topCandidates(1).first?.string.contains("External resource") == true }
                    let target = observations.first { $0.topCandidates(1).first?.string.contains("docs://") == true }
                    precondition(warning != nil && target != nil && warning!.boundingBox.minY > target!.boundingBox.maxY,
                                 "Explicit warnings must appear above prominent resource targets")
                    precondition(text.contains("#examples") && text.contains("Allow once") && text.contains("Deny"),
                                 "Long URIs must wrap through their fragment while approval controls remain available")
                }
                if name == "floating-uri-inputs.png" {
                    let recognition = VNRecognizeTextRequest()
                    recognition.recognitionLevel = .accurate
                    try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([recognition])
                    let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                    precondition(text.contains("POST") && text.contains("Invoice recipient"),
                                 "Promoting a URI must not hide unknown potentially decision-critical inputs")
                }
                if name == "control-center-finished.png" || name == "floating-short-screen.png" {
                    let recognition = VNRecognizeTextRequest()
                    recognition.recognitionLevel = .accurate
                    try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([recognition])
                    let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                    precondition(name == "control-center-finished.png" ? text.contains("Updated the focus order") :
                                    text.contains("More request details"),
                                 "Latest output and overflowed decision evidence must remain discoverable: \(name)")
                }
                if name == "control-center.png" || name == "control-center-disconnected.png" {
                    let recognition = VNRecognizeTextRequest()
                    recognition.recognitionLevel = .accurate
                    try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([recognition])
                    let right = (recognition.results ?? []).filter { $0.boundingBox.minX > 0.68 }
                        .compactMap { $0.topCandidates(1).first?.string }
                    if name == "control-center.png" {
                        precondition(right.joined(separator: " ").contains("expired-token") &&
                                     !right.joined(separator: " ").contains("Read the relevant"),
                                     "Only agent responses, not tool details, belong in the response feed. Found: \(right)")
                    } else {
                        precondition(right.contains("Disconnected"), "The agent state must not wrap in the middle of a word")
                    }
                }
                if name == "control-center-no-results.png" || name == "control-center-activity-waiting.png" || name == "floating-command.png" {
                    let recognition = VNRecognizeTextRequest()
                    recognition.recognitionLevel = .accurate
                    try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([recognition])
                    let lines = recognition.results ?? []
                    let text = lines.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                    if name == "control-center-no-results.png" {
                        precondition(text.contains("No matching sessions") && !text.contains("caught up"),
                                     "Combined search and waiting filters must not falsely announce all-clear. Found: \(text)")
                    } else if name == "control-center-activity-waiting.png" {
                        precondition(text.contains("Decision waiting") && text.contains("Review"),
                                     "Activity with a pending request must show an actionable Review banner")
                    } else {
                        let allow = lines.first { $0.topCandidates(1).first?.string == "Allow once" }
                        let deny = lines.first { $0.topCandidates(1).first?.string == "Deny" }
                        precondition(allow != nil && deny != nil && abs(allow!.boundingBox.midY - deny!.boundingBox.midY) < 0.035,
                                     "The one-time Allow and Deny actions must be grouped on the same row")
                    }
                }
                if name == "control-center-connections.png" {
                    let recognition = VNRecognizeTextRequest()
                    recognition.recognitionLevel = .accurate
                    try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([recognition])
                    let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                    precondition(text.contains("Connected") && text.contains("Not connected"),
                                 "Rendered connection groups must remain findable. Found: \(text)")
                }
                if name.hasPrefix("subagent-management") {
                    func managementText() throws -> [VNRecognizedTextObservation] {
                        let image = capture.bitmapImageRepForCachingDisplay(in: capture.bounds)!
                        capture.cacheDisplay(in: capture.bounds, to: image)
                        let recognition = VNRecognizeTextRequest()
                        recognition.recognitionLevel = .accurate
                        try VNImageRequestHandler(cgImage: image.cgImage!, options: [:]).perform([recognition])
                        return recognition.results ?? []
                    }
                    let rendered = try managementText().compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                    precondition(rendered.contains("Add subagent") && rendered.contains("Create subagent") &&
                        rendered.contains("model credits") && rendered.contains("Ended helpers") && rendered.contains("Remove from list"),
                        "Management must visibly separate paid creation from removing ended helpers: \(rendered)")
                    if name == "subagent-management.png" {
                        window.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                        pumpNativeEvents()
                        func clickManagement(_ label: String) throws {
                            let item = try managementText().first { $0.topCandidates(1).first?.string.contains(label) == true }!
                            let point = capture.convert(NSPoint(x: item.boundingBox.midX * capture.bounds.width,
                                y: (capture.isFlipped ? 1 - item.boundingBox.midY : item.boundingBox.midY) * capture.bounds.height), to: nil)
                            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                                NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!, atStart: false)
                            }
                            pumpNativeEvents()
                        }
                        let before = visual.steeringWorkspace.history["visual-0"]?.count ?? 0
                        try clickManagement("Create subagent")
                        precondition((visual.steeringWorkspace.history["visual-0"]?.count ?? 0) == before,
                                     "Empty creation fields must disable Create")
                        for (placeholder, value) in [("Subagent name", "UI reviewer"), ("Instructions for this subagent", "Review the UI fixture")] {
                            try clickManagement(placeholder)
                            guard let editor = window.firstResponder as? NSTextInputClient else {
                                preconditionFailure("Management fields must accept native text input")
                            }
                            editor.insertText(value, replacementRange: NSRange(location: NSNotFound, length: 0))
                            pumpNativeEvents()
                        }
                        try clickManagement("Create subagent")
                        let receipt = visual.steeringWorkspace.history["visual-0"]?.last
                        precondition(receipt?.action == "create_subagent" && receipt?.agentName == "UI reviewer" &&
                            receipt?.message == "Review the UI fixture" && receipt?.agentType == "general-purpose",
                            "The actual Create button must submit the entered fields, not the main chat draft")
                        visual.error = nil
                        window.orderOut(nil)
                    }
                }
                if name.hasPrefix("agent-hierarchy") {
                    let scroll = descendants(capture).compactMap { $0 as? NSScrollView }.first!
                    precondition(scroll.documentView!.frame.width <= scroll.contentSize.width + 1 &&
                                 scroll.documentView!.frame.height <= scroll.contentSize.height + 1,
                                 "Fit must keep the whole org chart inside its viewport: \(name), document=\(scroll.documentView!.frame.size), viewport=\(scroll.contentSize)")
                    let recognition = VNRecognizeTextRequest()
                    recognition.recognitionLevel = .accurate
                    try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([recognition])
                    let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                    if name.contains("large") {
                        precondition(text.contains("27 hidden inactive agents") && text.contains("2 failed"),
                                     "A large team's inactive block and failure count must stay separate and visible")
                    }
                    precondition(text.contains("Fit") && text.contains("100%"), "Large charts must have fit and readable-size controls")
                    if name.contains("idle") {
                        precondition(text.contains("Main agent") && text.contains("Working helper") &&
                                     text.contains("19 idle subagents") && !text.contains("Resting"),
                                     "One running and nineteen idle helpers must show only main, working helper and idle-group tiles")
                    } else if !name.contains("large") && !name.contains("deep") {
                        precondition(text.contains("Design lead") && !text.contains("Nested reviewer") &&
                                     text.contains("1 idle subagent") && text.contains("1 hidden inactive agent"),
                                     "The chart must group idle helpers separately from completed/stopped helpers: \(name)")
                        precondition(!text.contains("Stopped helper"), "Inactive agents must start folded")
                        func bounds(_ label: String) -> CGRect {
                            (recognition.results ?? []).first { $0.topCandidates(1).first?.string == label }!.boundingBox
                        }
                        let lead = bounds("Design lead"), peer = bounds("Code explorer")
                        precondition(abs(lead.midY - peer.midY) < 0.035 && abs(lead.midX - peer.midX) > 0.1,
                                     "Sibling agents must sit side by side in an org chart, not in a list")
                        precondition(bounds("Main agent").midY > lead.midY,
                                     "Children must be laid out below their actual parent")
                    }
                    if name == "agent-hierarchy.png" || name == "agent-hierarchy-small.png" || name == "agent-hierarchy-idle.png" {
                        window.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                        pumpNativeEvents()
                        func hierarchyText() throws -> [VNRecognizedTextObservation] {
                            let image = capture.bitmapImageRepForCachingDisplay(in: capture.bounds)!
                            capture.cacheDisplay(in: capture.bounds, to: image)
                            let recognition = VNRecognizeTextRequest()
                            recognition.recognitionLevel = .accurate
                            try VNImageRequestHandler(cgImage: image.cgImage!, options: [:]).perform([recognition])
                            return recognition.results ?? []
                        }
                        func hierarchyClick(_ label: String) throws {
                            guard let item = try hierarchyText().first(where: { $0.topCandidates(1).first?.string.contains(label) == true }) else {
                                preconditionFailure("The hierarchy must display \(label)")
                            }
                            let point = capture.convert(NSPoint(x: item.boundingBox.midX * capture.bounds.width,
                                y: (capture.isFlipped ? 1 - item.boundingBox.midY : item.boundingBox.midY) * capture.bounds.height), to: nil)
                            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                                window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
                                pumpNativeEvents()
                            }
                            for _ in 0..<8 { RunLoop.current.run(until: Date().addingTimeInterval(0.025)) }
                        }
                        if name == "agent-hierarchy-idle.png" {
                            try hierarchyClick("19 idle subagents")
                            try hierarchyClick("100%")
                            precondition(scroll.documentView!.frame.width > scroll.contentSize.width,
                                         "Expanded idle agents must be available at readable size by scrolling")
                            scroll.contentView.scroll(to: NSPoint(x: scroll.documentView!.frame.width - scroll.contentSize.width, y: 0))
                            scroll.reflectScrolledClipView(scroll.contentView)
                            pumpNativeEvents()
                            try hierarchyClick("Resting 19")
                            precondition(hierarchySelection == "idle-19", "Expanded idle helpers must open their exact chat")
                            try hierarchyClick("Hide idle")
                            let collapsedIdle = try hierarchyText()
                            precondition(!collapsedIdle.contains {
                                $0.topCandidates(1).first?.string.contains("Resting") == true
                            }, "Collapsing the idle group must hide its individual helpers")
                            try hierarchyClick("Fit")
                            let fittedIdle = try hierarchyText()
                            precondition(fittedIdle.contains {
                                $0.topCandidates(1).first?.string.contains("19 idle subagents") == true
                            }, "The idle group must return after collapsing")
                        } else if name == "agent-hierarchy-small.png" {
                            try hierarchyClick("1 idle subagent")
                            try hierarchyClick("100%")
                            precondition(scroll.documentView!.frame.height > scroll.contentSize.height,
                                         "Actual-size zoom must allow scrolling rather than clip a larger chart")
                            try hierarchyClick("Fit")
                            precondition(scroll.documentView!.frame.height <= scroll.contentSize.height + 1,
                                         "Fit must restore the complete chart after zooming")
                        } else {
                        try hierarchyClick("Design lead")
                        precondition(hierarchySelection == "design-lead", "Hierarchy nodes must select their exact agent")
                        try hierarchyClick("1 idle subagent")
                        let expandedText = try hierarchyText()
                        let expandedLead = expandedText.first { $0.topCandidates(1).first?.string == "Design lead" }!
                        let expandedChild = expandedText.first { $0.topCandidates(1).first?.string == "Nested reviewer" }!
                        precondition(expandedChild.boundingBox.midY < expandedLead.boundingBox.midY,
                                     "Expanded idle descendants must appear below their actual parent")
                        try hierarchyClick("Nested reviewer")
                        precondition(hierarchySelection == "nested-reviewer", "Nested clicks must not select their parent")
                        try hierarchyClick("Hide 1 branch")
                        let folded = try hierarchyText()
                        precondition(!folded.contains { $0.topCandidates(1).first?.string.contains("Nested reviewer") == true },
                                     "Folding a branch must actually hide its descendants")
                        try hierarchyClick("Show 1 branch")
                        try hierarchyClick("1 hidden inactive agent")
                        try hierarchyClick("Stopped helper")
                        precondition(hierarchySelection == "nested-reviewer", "Stopped hierarchy nodes must not be interactive")
                        try hierarchyClick("Hide inactive agents")
                        let hidden = try hierarchyText()
                        precondition(!hidden.contains { $0.topCandidates(1).first?.string.contains("Stopped helper") == true },
                                     "Inactive expansion must be reversible")
                        try hierarchyClick("Main agent")
                        precondition(hierarchySelection == nil, "The main tile must still select the main chat")
                        }
                        window.orderOut(nil)
                    }
                }
                if name == "control-center-responses.png" || name == "copy-actions.png" {
                  if name == "control-center-responses.png" {
                    let recognition = VNRecognizeTextRequest()
                    recognition.recognitionLevel = .accurate
                    try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([recognition])
                    let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                    precondition(text.contains("Tools & thinking") && text.contains("Thinking"),
                                 "Chat must show distinct tool/thinking entries without first expanding the activity panel. Found: \(text)")
                  }
                  let examples = name == "copy-actions.png" ? copyExamples :
                    [("Copy", "function closeMenu(trigger: HTMLElement) {\n  setOpen(false);\n  trigger.focus();\n}\n")]
                  for (label, expectedCopy) in examples {
                    let recognition = VNRecognizeTextRequest()
                    recognition.recognitionLevel = .accurate
                    try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([recognition])
                    guard var copy = recognition.results?.first(where: { $0.topCandidates(1).first?.string.hasSuffix(label) == true }) else {
                        preconditionFailure("A visible \(label) action is required")
                    }
                    let pasteboard = NSPasteboard.general
                    let originalText = pasteboard.string(forType: .string)
                    let original = (pasteboard.pasteboardItems ?? []).map { item in
                        let saved = NSPasteboardItem()
                        for type in item.types {
                            if let data = item.data(forType: type) { saved.setData(data, forType: type) }
                        }
                        return saved
                    }
                    let wasVisible = window.isVisible
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    let activationDeadline = Date().addingTimeInterval(2)
                    while !NSApp.isActive && Date() < activationDeadline {
                        pumpNativeEvents()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                    }
                    precondition(NSApp.isActive && window.isKeyWindow,
                                 "Pointer interaction requires an active fixture window (app: \(NSApp.isActive), key: \(window.isKeyWindow))")
                    capture.layoutSubtreeIfNeeded()
                    let activeBitmap = capture.bitmapImageRepForCachingDisplay(in: capture.bounds)!
                    capture.cacheDisplay(in: capture.bounds, to: activeBitmap)
                    try VNImageRequestHandler(cgImage: activeBitmap.cgImage!, options: [:]).perform([recognition])
                    guard let activeCopy = recognition.results?.first(where: { $0.topCandidates(1).first?.string.hasSuffix(label) == true }) else {
                        preconditionFailure("The \(label) action must remain visible after activating the window")
                    }
                    copy = activeCopy
                    let location = capture.convert(NSPoint(x: copy.boundingBox.midX * capture.bounds.width,
                        y: (capture.isFlipped ? 1 - copy.boundingBox.midY : copy.boundingBox.midY) * capture.bounds.height), to: nil)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        window.sendEvent(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
                        pumpNativeEvents()
                    }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    let copiedCode = pasteboard.string(forType: .string)
                    pasteboard.clearContents()
                    precondition(original.isEmpty || pasteboard.writeObjects(original), "The clipboard fixture must restore the previous contents")
                    if !wasVisible { window.orderOut(nil) }
                    precondition(copiedCode == expectedCopy, "\(label) must preserve the entire supplied text exactly (clipboard unchanged: \(copiedCode == originalText))")
                  }
                }
                if name == "control-center-responses.png" {
                    let recognition = VNRecognizeTextRequest()
                    recognition.recognitionLevel = .accurate
                    try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([recognition])
                    guard let worker = recognition.results?.first(where: {
                        $0.topCandidates(1).first?.string.hasPrefix("Code explorer") == true
                    }) else { preconditionFailure("The clickable Code explorer row must remain visible") }
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    pumpNativeEvents()
                    let location = capture.convert(NSPoint(x: worker.boundingBox.midX * capture.bounds.width,
                        y: (capture.isFlipped ? 1 - worker.boundingBox.midY : worker.boundingBox.midY) * capture.bounds.height), to: nil)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        window.sendEvent(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
                        pumpNativeEvents()
                    }
                    for _ in 0..<8 {
                        capture.layoutSubtreeIfNeeded()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.025))
                    }
                    let childBitmap = capture.bitmapImageRepForCachingDisplay(in: capture.bounds)!
                    capture.cacheDisplay(in: capture.bounds, to: childBitmap)
                    try VNImageRequestHandler(cgImage: childBitmap.cgImage!, options: [:]).perform([recognition])
                    let childText = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                    precondition(childText.contains("Stop subagent") && childText.contains("Message Code explorer"),
                                 "Clicking a worker must open its own composer and controls. Found: \(childText)")
                    precondition(childText.contains("Subagent chat") && childText.contains("Reading menu.tsx") &&
                                 !childText.contains("Inspect project files"),
                                 "Helper chat must show distinct identity and only its own compact activity. Found: \(childText)")
                    try childBitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("control-center-subagent-chat.png"))
                    window.orderOut(nil)
                }
            }
            try capture(VStack(alignment: .leading, spacing: 26) {
                ForEach(copyExamples.indices, id: \.self) { index in
                    CopyTextButton(text: copyExamples[index].1, label: copyExamples[index].0)
                }
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Palette.surface),
                        width: 420, height: 220, name: "copy-actions.png")
            let presenceLineup = HStack(alignment: .top, spacing: 24) {
                VStack {
                    Text("Main agent · working")
                    AgentIllustration(presence: .working, time: 0.25, isLead: true).frame(width: 220, height: 166)
                }
                VStack {
                    Text("Main agent · idle")
                    AgentIllustration(presence: .resting, time: 3.5, isLead: true).frame(width: 220, height: 166)
                }
                VStack {
                    Text("Stopped")
                    AgentIllustration(presence: .stopped, isLead: true).frame(width: 160, height: 121)
                }
                VStack {
                    Text("Subagent")
                    AgentIllustration(presence: .working, time: 0.25).frame(width: 88, height: 68)
                }
            }.font(WorkspaceType.text(13)).foregroundStyle(Palette.ink).padding(20).background(Palette.surface)
            try capture(presenceLineup, width: 860, height: 235, name: "agent-presence-lineup.png")
            try capture(presenceLineup, width: 860, height: 235, name: "agent-presence-lineup-dark.png", appearance: .darkAqua)
            var hierarchySession = visual.selected!
            hierarchySession.requests = []
            hierarchySession.team = try JSONDecoder().decode(SubagentTeam.self, from: Data("""
            {"agents":[
              {"id":"design-lead","name":"Design lead","task":"Review the interface","status":"running","parentKnown":true},
              {"id":"nested-reviewer","name":"Nested reviewer","task":"Check keyboard access","status":"idle","parentKnown":true,"parentAgentID":"design-lead"},
              {"id":"code-explorer","name":"Code explorer","task":"Inspect the existing implementation","status":"running","parentKnown":true},
              {"id":"stopped-helper","name":"Stopped helper","task":"Retained briefly after cancellation","status":"cancelled","parentKnown":true}
            ],"runningCount":2,"idleCount":1,"truncated":false}
            """.utf8))
            let hierarchyView = AgentHierarchyView(store: visual, session: hierarchySession, selectedAgentID: nil) {
                hierarchySelection = $0
            }.padding(20).background(Palette.surface)
            try capture(hierarchyView, width: 1000, height: 800, name: "agent-hierarchy.png")
            try capture(hierarchyView, width: 1000, height: 800, name: "agent-hierarchy-dark.png", appearance: .darkAqua)
            try capture(hierarchyView, width: 780, height: 480, name: "agent-hierarchy-small.png")
            try capture(hierarchyView, width: 780, height: 480, name: "agent-hierarchy-small-dark.png", appearance: .darkAqua)
            let managementTeam = visual.registry.sessions["visual-0"]!.team!
            let managementWorkspace = visual.steeringWorkspace
            try receive(["type": "team", "sessionID": "visual-0", "team": [
                "agents": [["id": "ended-reviewer", "name": "Ended reviewer", "task": "Finished review", "status": "completed"]],
                "runningCount": 0, "idleCount": 0, "truncated": false
            ]])
            try capture(SubagentManagementView(store: visual, sessionID: "visual-0"), width: 540, height: 620,
                        name: "subagent-management.png")
            visual.steeringWorkspace = managementWorkspace
            try capture(SubagentManagementView(store: visual, sessionID: "visual-0"), width: 540, height: 620,
                        name: "subagent-management-dark.png", appearance: .darkAqua)
            try receive(["type": "team", "sessionID": "visual-0", "team":
                JSONSerialization.jsonObject(with: JSONEncoder().encode(managementTeam))])
            var idleHierarchy = hierarchySession
            idleHierarchy.team = try JSONDecoder().decode(SubagentTeam.self, from: JSONSerialization.data(withJSONObject: [
                "agents": (0..<20).map { index -> [String: Any] in
                    ["id": "idle-\(index)", "name": index == 0 ? "Working helper" : "Resting \(index)",
                     "task": "Review the current task", "status": index == 0 ? "running" : "idle", "parentKnown": true]
                }, "runningCount": 1, "idleCount": 19, "truncated": false
            ]))
            let idleHierarchyView = AgentHierarchyView(store: visual, session: idleHierarchy, selectAgent: {
                hierarchySelection = $0
            }).padding(20).background(Palette.surface)
            try capture(idleHierarchyView, width: 1000, height: 800, name: "agent-hierarchy-idle.png")
            try capture(idleHierarchyView, width: 780, height: 480, name: "agent-hierarchy-idle-dark.png", appearance: .darkAqua)
            var largeHierarchy = hierarchySession
            let largeAgents: [[String: Any]] = (0..<30).map { index in
                ["id": "wide-\(index)", "name": "Helper \(index)", "task": "A longer task description that must fit the available width",
                 "status": index < 3 ? "running" : index >= 28 ? "failed" : "completed", "parentKnown": true]
            }
            largeHierarchy.team = try JSONDecoder().decode(SubagentTeam.self, from: JSONSerialization.data(withJSONObject: [
                "agents": largeAgents, "runningCount": 3, "idleCount": 0, "truncated": false
            ]))
            let largeHierarchyView = AgentHierarchyView(store: visual, session: largeHierarchy, selectAgent: { _ in })
                .padding(20).background(Palette.surface)
            try capture(largeHierarchyView, width: 640, height: 480, name: "agent-hierarchy-large.png")
            try capture(largeHierarchyView, width: 640, height: 480, name: "agent-hierarchy-large-dark.png", appearance: .darkAqua)
            let deepAgents: [[String: Any]] = (0..<20).map { index in
                var agent: [String: Any] = ["id": "deep-\(index)", "name": "Nested helper \(index)",
                    "task": "Preserve readable content and exact ancestry at every depth", "status": "running", "parentKnown": true]
                if index > 0 { agent["parentAgentID"] = "deep-\(index - 1)" }
                return agent
            }
            largeHierarchy.team = try JSONDecoder().decode(SubagentTeam.self, from: JSONSerialization.data(withJSONObject: [
                "agents": deepAgents, "runningCount": 20, "idleCount": 0, "truncated": false
            ]))
            try capture(AgentHierarchyView(store: visual, session: largeHierarchy, selectAgent: { _ in })
                .padding(20).background(Palette.surface), width: 640, height: 480, name: "agent-hierarchy-deep.png")
            try capture(DashboardView(store: visual), width: 1120, height: 800, name: "control-center.png")
            try capture(DashboardView(store: visual), width: 960, height: 620, name: "control-center-small.png")
            try capture(DashboardView(store: visual), width: 1120, height: 800, name: "control-center-dark.png", appearance: .darkAqua)
            try capture(DashboardView(store: visual), width: 960, height: 620, name: "control-center-small-dark.png", appearance: .darkAqua)
            visual.server.onDisconnect("visual-6")
            visual.server.onDisconnect("visual-7")
            try capture(DashboardView(store: visual), width: 1120, height: 800, name: "control-center-connections.png")
            try capture(DashboardView(store: visual), width: 1120, height: 800, name: "control-center-activity-waiting.png")
            visual.waitingOnly = true
            try capture(DashboardView(store: visual), width: 960, height: 620, name: "control-center-no-results.png")
            visual.waitingOnly = false
            visual.select("visual-6")
            try capture(DashboardView(store: visual), width: 960, height: 620, name: "control-center-disconnected.png")
            visual.select("visual-0", request: "visual-request")
            let empty = Store(directory: fixtureRoot.appendingPathComponent("empty"), defaults: defaults)
            try capture(DashboardView(store: empty), width: 960, height: 620, name: "control-center-empty.png")
            empty.waitingOnly = true
            try capture(DashboardView(store: empty), width: 960, height: 620, name: "control-center-no-decisions.png")
            empty.stop()
            try capture(FloatingView(store: visual, openCenter: {}), width: 420, height: 560, name: "floating-command.png")
            try capture(FloatingView(store: visual, openCenter: {}), width: 420, height: 560, name: "floating-command-dark.png", appearance: .darkAqua)
            let colorChoices = SessionColorChoices(store: visual, sessionID: "visual-0")
            let colorsHeight = NSHostingView(rootView: colorChoices).fittingSize.height.rounded(.up)
            try capture(colorChoices, width: 280, height: colorsHeight, name: "session-color-picker.png")
            try capture(colorChoices, width: 280, height: colorsHeight, name: "session-color-picker-dark.png", appearance: .darkAqua)
            try capture(FloatingView(store: visual, openCenter: {}), width: 420, height: 560, name: "floating-command.png")
            window.makeKey()
            let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                         isARepeat: false, keyCode: 36)!
            precondition(window.performKeyEquivalent(with: enter), "Return must invoke the focused notification's Allow once action")
            precondition(visual.requestErrors["visual-request"] != nil, "Return must dispatch the exact pending request (the fixture has no transport)")
            visual.requestErrors.removeValue(forKey: "visual-request")
            guard let instructions = descendants(window.contentView!).compactMap({ $0 as? NSTextField }).first(where: {
                $0.placeholderString == "Denial instructions (optional)"
            }) else { preconditionFailure("Denial instructions must be a native editable field") }
            window.makeFirstResponder(instructions)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            _ = window.performKeyEquivalent(with: enter)
            precondition(visual.requestErrors["visual-request"] == nil, "Return must not approve while editing denial instructions")
            try capture(FloatingView(store: visual, openCenter: {}), width: 420, height: 500, name: "floating-short-screen.png")
            try capture(FloatingView(store: visual, openCenter: {}), width: 420, height: 500, name: "floating-short-screen-dark.png", appearance: .darkAqua)
            visual.setColor(0x9654CE, for: visual.selected!)
            visual.floatingExpanded = true
            try capture(FloatingView(store: visual, openCenter: {}), width: 600, height: 760, name: "floating-expanded.png")
            try receive(["type": "error", "sessionID": "visual-0", "requestID": "visual-request",
                         "text": "Reply could not be delivered. Check the agent connection before trying again."])
            try capture(FloatingView(store: visual, openCenter: {}), width: 600, height: 760, name: "floating-error.png")
            try capture(FloatingView(store: visual, openCenter: {}), width: 600, height: 760, name: "floating-error-dark.png", appearance: .darkAqua)
            visual.requestErrors.removeValue(forKey: "visual-request")
            visual.sending.insert("visual-request")
            try capture(FloatingView(store: visual, openCenter: {}), width: 600, height: 760, name: "floating-sending.png")
            try capture(FloatingView(store: visual, openCenter: {}), width: 600, height: 760, name: "floating-sending-dark.png", appearance: .darkAqua)
            visual.sending.remove("visual-request")
            let diff = "--- a/auth/refresh.ts\n+++ b/auth/refresh.ts\n@@ -8,3 +8,4 @@\n-const token = cache.get(user.id)\n+const token = await refreshToken(user.id)\n+cache.set(user.id, token)\n return token\n"
            let diffDetail = String(data: try JSONSerialization.data(withJSONObject: [
                "filePath": "/Projects/accounts/auth/refresh.ts", "diff": diff,
                "intention": "Refresh the expired token before caching it."
            ]), encoding: .utf8)!
            try receive(["type": "resolved", "sessionID": "visual-0", "requestID": "visual-request", "decision": "deny"])
            try receive(["type": "request", "sessionID": "visual-0", "request": [
                "id": "visual-diff", "kind": "permission", "title": "Update token refresh?", "detail": diffDetail,
                "questions": [], "autoEligible": false
            ]])
            visual.replyWorkspace.next(requestIDs: ["visual-diff"])
            try capture(FloatingView(store: visual, openCenter: {}), width: 600, height: 760, name: "floating-diff.png")
            try capture(FloatingView(store: visual, openCenter: {}), width: 600, height: 760, name: "floating-diff-dark.png", appearance: .darkAqua)
            visual.floatingExpanded = false
            visual.replyWorkspace.next(requestIDs: ["visual-question"])
            visual.replyWorkspace.drafts["visual-question"] = ReplyDraft(freeText: ["0": "Use banker's rounding for the final total."])
            try capture(FloatingView(store: visual, openCenter: {}), width: 420, height: 560, name: "floating-question.png")
            try capture(FloatingView(store: visual, openCenter: {}), width: 420, height: 560, name: "floating-question-dark.png", appearance: .darkAqua)
            let otherFields = descendants(window.contentView!).compactMap { $0 as? NSTextField }
            precondition(otherFields.contains { $0.placeholderString == "Type your own answer" && $0.visibleRect.height > 20 },
                         "A short question must show its editable Other answer, not hide it in a collapsed scroll strip")
            visual.sending.insert("visual-question")
            try capture(FloatingView(store: visual, openCenter: {}), width: 420, height: 560, name: "floating-question-sending.png")
            let sendingFields = descendants(window.contentView!).compactMap { $0 as? NSTextField }
            precondition(sendingFields.contains { $0.placeholderString == "Type your own answer" && !$0.isEnabled },
                         "A dispatched question must keep its answer visible but prevent edits until delivery completes")
            visual.sending.remove("visual-question")
            visual.select("visual-2")
            for (id, kind, title, text) in [
                ("reason", "reasoning", "Published reasoning", "The focus order should follow the visible navigation, including the overflow menu."),
                ("response", "assistant", "Agent response", """
                ## A clearer keyboard path

                The overflow menu now follows the visible navigation. `Escape` returns focus to the trigger.

                ```typescript
                function closeMenu(trigger: HTMLElement) {
                  setOpen(false);
                  trigger.focus();
                }
                ```

                - Keep the current selection.
                - Check tab order before continuing.
                """)
            ] {
                try receive(["type": "activity", "sessionID": "visual-2", "activity": [
                    "id": id, "kind": kind, "title": title, "detail": text, "status": "complete",
                    "timestamp": ISO8601DateFormatter().string(from: Date())
                ]])
            }
            try capture(DashboardView(store: visual), width: 1120, height: 800, name: "control-center-responses.png")
            try capture(DashboardView(store: visual), width: 1120, height: 800, name: "control-center-responses-dark.png", appearance: .darkAqua)
            try capture(DashboardView(store: visual), width: 960, height: 620, name: "control-center-responses-small.png")
            try capture(DashboardView(store: visual), width: 960, height: 620, name: "control-center-responses-small-dark.png", appearance: .darkAqua)
            try capture(DashboardView(store: visual), width: 1120, height: 800, name: "control-center-activity.png")
            try capture(DashboardView(store: visual), width: 960, height: 620, name: "control-center-controls-small.png")
            try capture(DashboardView(store: visual), width: 960, height: 620, name: "control-center-controls-dark.png", appearance: .darkAqua)
            try receive(["type": "activity", "sessionID": "visual-2", "activity": [
                "id": "new-reason", "kind": "reasoning", "title": "Published reasoning",
                "detail": "Comparing focus order against the visible menu.", "status": "running",
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]])
            try capture(DashboardView(store: visual), width: 960, height: 620, name: "control-center-thinking.png")
            try receive(["type": "activity", "sessionID": "visual-2", "activity": [
                "id": "new-response", "kind": "assistant", "title": "Agent response",
                "detail": "Updated the focus order. The keyboard check passed.", "status": "complete",
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]])
            try receive(["type": "state", "sessionID": "visual-2", "state": "ready", "text": "Agent idle"])
            try capture(DashboardView(store: visual), width: 960, height: 620, name: "control-center-finished.png")
            visual.select("visual-1", request: "visual-question")
            try capture(DashboardView(store: visual), width: 960, height: 620, name: "control-center-question.png")
            visual.select("visual-2")
            try capture(SessionAutoYesView(store: visual, session: visual.selected!).padding(24).background(Palette.background),
                        width: 550, height: 220, name: "session-automation.png")
            try receive(["type": "capabilities", "sessionID": "visual-2", "sessionAutoYes": true, "steering": true])
            visual.setSessionDangerousAutoYes("visual-2", enabled: true)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                try capture(DashboardView(store: visual), width: 960, height: 620,
                            name: "control-center-dangerous-\(name).png", appearance: appearance)
            }
            visual.setSessionDangerousAutoYes("visual-2", enabled: false)
            try receive(["type": "capabilities", "sessionID": "visual-0", "sessionAutoYes": true, "steering": true])
            visual.setSessionDangerousAutoYes("visual-0", enabled: true)
            visual.replyWorkspace.next(requestIDs: ["visual-request"])
            try capture(FloatingView(store: visual, openCenter: {}), width: 600, height: 760, name: "floating-dangerous.png")
            visual.setSessionDangerousAutoYes("visual-0", enabled: false)
            let settingsHeight = NSHostingView(rootView: SettingsView(store: visual)).fittingSize.height.rounded(.up)
            try capture(SettingsView(store: visual), width: 550, height: settingsHeight, name: "settings.png")
            try capture(SettingsView(store: visual), width: 550, height: settingsHeight, name: "settings-dark.png", appearance: .darkAqua)
            do {
                let phone = Store(directory: fixtureRoot.appendingPathComponent("phone-visual"), defaults: defaults,
                                  mobileResources: fixtureRoot.appendingPathComponent("mobile-resources"))
                defer { phone.mobile.setEnabled(false); phone.stop() }
                var ready = false
                phone.server.onReady = { ready = true }
                try phone.server.start()
                func waitForPhone(_ predicate: () -> Bool) {
                    let deadline = Date().addingTimeInterval(10)
                    while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.025)) }
                    precondition(predicate(), "The native phone capture fixture failed: \(phone.mobile.error ?? "no error")")
                }
                waitForPhone { ready }
                phone.mobile.setEnabled(true)
                waitForPhone { phone.mobile.status != nil }
                phone.mobile.invite()
                waitForPhone { phone.mobile.pairing != nil && phone.mobile.status?.pairingCode != nil }
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    phone.appearanceMode = appearance == .aqua ? .light : .dark
                    try capture(SettingsView(store: phone), width: 550, height: 680, name: "settings-phone-\(name).png", appearance: appearance)
                    try capture(ScrollView { MobileSettingsView(mobile: phone.mobile).padding(28) }.background(Palette.background).foregroundStyle(Palette.ink).tint(Palette.accent),
                                width: 550, height: 680, name: "phone-pairing-\(name).png", appearance: appearance)
                }
            }
            let setupResources = fixtureRoot.appendingPathComponent("setup-resources")
            let setupBin = setupResources.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: setupBin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: setupResources.appendingPathComponent("bridge/dist"), withIntermediateDirectories: true)
            for name in ["node", "copilot", "claude", "notify"] {
                let file = setupBin.appendingPathComponent(name)
                try Data("#!/bin/sh\nif [ \"$1\" = '--version' ]; then printf 'v22.18.0\\n'; else echo 'Fixture: extension installation was refused' >&2; exit 1; fi\n".utf8).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            }
            try Data().write(to: setupResources.appendingPathComponent("bridge/dist/cli.js"))
            empty.setupSnapshot = try AgentSetup.inspect(resources: setupResources, path: setupBin.path, copilotHome: fixtureRoot.appendingPathComponent("copilot-home"))
            try capture(AgentSetupView(store: empty), width: 960, height: 620, name: "welcome-copilot.png")
            try capture(AgentSetupView(store: empty), width: 960, height: 620, name: "welcome-copilot-dark.png", appearance: .darkAqua)
            empty.setupAgent = .claude
            try capture(AgentSetupView(store: empty), width: 960, height: 620, name: "welcome-claude.png")
            try capture(AgentSetupView(store: empty), width: 960, height: 620, name: "welcome-claude-dark.png", appearance: .darkAqua)
            precondition(empty.setupConnectionCount(.copilot) == 0 && empty.setupConnectionCount(.claude) == 0,
                         "Installed tools must never be labeled connected")
            empty.setupSnapshot = try AgentSetup.inspect(resources: nil, path: "", copilotHome: fixtureRoot.appendingPathComponent("missing-home"))
            try capture(AgentSetupView(store: empty), width: 960, height: 620, name: "welcome-missing.png")
            empty.setupSnapshot = try AgentSetup.inspect(resources: setupResources, path: setupBin.path, copilotHome: fixtureRoot.appendingPathComponent("copilot-home"))
            empty.setupAgent = .copilot
            empty.installCopilotExtension()
            empty.setupAgent = .claude
            let setupDeadline = Date().addingTimeInterval(5)
            while empty.setupBusy && Date() < setupDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            precondition(!empty.setupBusy, "Fixture installer must finish")
            try capture(AgentSetupView(store: empty), width: 960, height: 620, name: "welcome-claude-after-error.png")
            empty.setupAgent = .copilot
            try capture(AgentSetupView(store: empty), width: 960, height: 620, name: "welcome-install-error.png")
            visual.setupSnapshot = try AgentSetup.inspect(resources: setupResources, path: setupBin.path, copilotHome: fixtureRoot.appendingPathComponent("copilot-home"))
            precondition(visual.setupConnectionCount(.copilot) > 0, "Only live bridge sessions count as connected")
            try capture(AgentSetupView(store: visual), width: 960, height: 620, name: "welcome-connected.png")
            visual.setupVisible = false
            let customOptions = (1...14).map { ["label": "Strategy \($0)", "description": "Review this migration approach"] }
            for (name, questions): (String, [[String: Any]]) in [
                ("long", [["id": "choice", "text": "Migration approach", "multiple": false, "allowFreeform": true, "options": customOptions]]),
                ("fixed", [["id": "choice", "text": "Migration approach", "multiple": false, "allowFreeform": false, "options": customOptions]]),
                ("multiple", [["id": "choice", "text": "Migration approach", "multiple": false, "allowFreeform": true, "options": customOptions],
                              ["id": "timing", "text": "When to migrate", "multiple": false, "allowFreeform": true, "options": customOptions]])
            ] {
                let id = "custom-\(name)"
                try receive(["type": "request", "sessionID": "visual-1", "request": [
                    "id": id, "kind": "question", "title": "Choose the migration strategy", "detail": "",
                    "questions": questions, "autoEligible": false
                ]])
                visual.replyWorkspace.next(requestIDs: [id])
                try capture(FloatingView(store: visual, openCenter: {}), width: 420, height: 500, name: "floating-custom-\(name).png")
                if name == "long" {
                    try capture(FloatingView(store: visual, openCenter: {}), width: 420, height: 500, name: "floating-custom-long-dark.png", appearance: .darkAqua)
                    visual.replyWorkspace.drafts[id] = ReplyDraft(selections: ["choice": ["Strategy 1"]])
                    try capture(FloatingView(store: visual, openCenter: {}), width: 420, height: 500, name: "floating-custom-focus.png")
                }
                try receive(["type": "resolved", "sessionID": "visual-1", "requestID": id, "decision": "deny"])
            }
            let uriStore = Store(directory: fixtureRoot.appendingPathComponent("uri"), defaults: defaults)
            try FileManager.default.createDirectory(at: uriStore.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { uriStore.stop() }
            for packet: [String: Any] in [
                ["type": "hello", "sessionID": "uri-session", "agent": "copilot", "cwd": "/Projects/docs"],
                ["type": "metadata", "sessionID": "uri-session", "title": "Check the setup guide"],
                ["type": "request", "sessionID": "uri-session", "request": [
                    "id": "uri-request", "kind": "permission", "title": "Read this resource?",
                    "detail": #"{"toolName":"Transport bookkeeper","serverName":"docs","arguments":{"uri":"https://example.org"},"intention":"Read the public setup guide."}"#,
                    "autoEligible": false, "questions": []
                ]]
            ] {
                uriStore.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: JSONSerialization.data(withJSONObject: packet)))
            }
            try capture(FloatingView(store: uriStore, openCenter: {}), width: 420, height: 560, name: "floating-uri.png")
            try capture(FloatingView(store: uriStore, openCenter: {}), width: 420, height: 560, name: "floating-uri-dark.png", appearance: .darkAqua)
            var previousURIRequest = "uri-request"
            for (name, detail) in [
                ("long", #"{"toolName":"Transport bookkeeper","warning":"External resource access.","arguments":{"uri":"docs://reference/auth?path=a%2Fb&version=2#examples"}}"#),
                ("inputs", #"{"uri":"https://example.org","method":"POST","recipient":"Invoice recipient"}"#)
            ] {
                for packet: [String: Any] in [
                    ["type": "resolved", "sessionID": "uri-session", "requestID": previousURIRequest, "decision": "deny"],
                    ["type": "request", "sessionID": "uri-session", "request": [
                        "id": "uri-\(name)", "kind": "permission", "title": "Read this resource?", "detail": detail,
                        "autoEligible": false, "questions": []
                    ]]
                ] {
                    uriStore.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: JSONSerialization.data(withJSONObject: packet)))
                }
                previousURIRequest = "uri-\(name)"
                precondition(uriStore.error == nil, "URI capture fixtures must persist their simulated reply history")
                try capture(FloatingView(store: uriStore, openCenter: {}), width: 420, height: 500, name: "floating-uri-\(name).png")
                if name == "long" {
                    try capture(FloatingView(store: uriStore, openCenter: {}), width: 420, height: 500, name: "floating-uri-long-dark.png", appearance: .darkAqua)
                }
            }
            visual.showSteering("visual-2")
            try capture(FloatingView(store: visual, openCenter: {}), width: 420, height: 560, name: "floating-steering.png")
            try capture(FloatingView(store: visual, openCenter: {}), width: 420, height: 560, name: "floating-steering-dark.png", appearance: .darkAqua)
            visual.stop()
            window.contentView = dashboard
        }
        let appDelegate = AppDelegate(store: store, backgroundLaunch: true)
        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        precondition(NSApp.appearance?.name == .darkAqua, "A saved Dark preference must apply before Notify presents its windows")
        let center = NSApp.windows.first { $0.title == "Notify" }!
        precondition(!center.isVisible, "Launcher startup must not open the control center")
        defer { appDelegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
        let previousWaiting = store.pending.count
        let dockPacket = try JSONSerialization.data(withJSONObject: [
            "type": "request", "sessionID": session.id,
            "request": ["id": "dock-test", "kind": "permission", "title": "Dock fixture",
                        "detail": "", "autoEligible": false, "questions": [], "supportsFeedback": true,
                        "permissionOptions": [["id": "session", "label": "Always this session", "detail": "Only fixture commands"]]]
        ])
        store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: dockPacket))
        precondition(!center.isVisible, "Incoming requests must not open the control center")
        precondition(NSApp.dockTile.badgeLabel == String(previousWaiting + 1), "Dock badge must count pending manual decisions")
        store.replyWorkspace.next(requestIDs: ["dock-test"])
        store.steeringSessionID = nil
        appDelegate.openCenter()
        for _ in 0..<8 { pumpNativeEvents(); RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        precondition(center.isKeyWindow,
                     "The Control Center focus regression must use the real focused window; active=\(NSApp.isActive), key=\(NSApp.keyWindow?.windowNumber ?? -1), expected=\(center.windowNumber), modal=\(NSApp.modalWindow != nil)")
        store.onAttentionChange?()
        func sendReturn(_ kind: UInt32, key: UInt32 = UInt32(kVK_Return), handled: Bool = true) {
            var event: EventRef?
            precondition(CreateEvent(nil, OSType(kEventClassKeyboard), kind, 0, 0, &event) == noErr)
            var identity = EventHotKeyID(signature: 0x4e745274, id: key)
            precondition(SetEventParameter(event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID),
                                          MemoryLayout<EventHotKeyID>.size, &identity) == noErr)
            precondition(SendEventToEventTarget(event, GetApplicationEventTarget()) == (handled ? noErr : OSStatus(eventNotHandledErr)),
                         handled ? "A visible notification must own the global Return hotkey" : "A confirmation must release the global Return hotkey")
        }
        sendReturn(UInt32(kEventHotKeyPressed))
        precondition(store.requestErrors["dock-test"] != nil,
                     "Global Return must dispatch the visible request through the real reply path")
        store.requestErrors.removeValue(forKey: "dock-test")
        sendReturn(UInt32(kEventHotKeyPressed))
        precondition(store.requestErrors["dock-test"] == nil, "Holding Return must not approve or retry twice")
        sendReturn(UInt32(kEventHotKeyReleased))
        sendReturn(UInt32(kEventHotKeyPressed), key: UInt32(kVK_DownArrow))
        sendReturn(UInt32(kEventHotKeyReleased), key: UInt32(kVK_DownArrow))
        sendReturn(UInt32(kEventHotKeyPressed))
        precondition(store.audit.first?.action == "Requested: Always this session - Only fixture commands",
                     "Arrow then Return must activate the highlighted offered scope through audit-before-dispatch")
        sendReturn(UInt32(kEventHotKeyReleased))
        sendReturn(UInt32(kEventHotKeyPressed), key: UInt32(kVK_ANSI_KeypadEnter))
        precondition(store.requestErrors["dock-test"] != nil, "Keypad Enter must have the same priority")
        store.sending.insert("dock-test")
        store.onAttentionChange?()
        store.requestErrors.removeValue(forKey: "dock-test")
        sendReturn(UInt32(kEventHotKeyPressed), key: UInt32(kVK_ANSI_KeypadEnter))
        precondition(store.requestErrors["dock-test"] == nil, "A held key must stay consumed while the reply is in flight")
        sendReturn(UInt32(kEventHotKeyReleased), key: UInt32(kVK_ANSI_KeypadEnter))
        func assertReturnReleased(_ message: String) {
            var reference: EventHotKeyRef?
            precondition(RegisterEventHotKey(UInt32(kVK_Return), 0, EventHotKeyID(signature: 0x54657374, id: 1),
                                             GetApplicationEventTarget(), 0, &reference) == noErr, message)
            if let reference { precondition(UnregisterEventHotKey(reference) == noErr) }
        }
        assertReturnReleased("Return must be released after key-up when the request is already sending")
        store.sending.remove("dock-test")
        store.onAttentionChange?()
        for key in [UInt32(kVK_Return), UInt32(kVK_ANSI_KeypadEnter)] {
            appDelegate.openCenter()
            for _ in 0..<8 { pumpNativeEvents(); RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            let search = descendants(center.contentView!).compactMap { $0 as? NSTextField }.first {
                $0.placeholderString == "Search sessions"
            }!
            precondition(center.makeFirstResponder(search), "The real Control Center search must accept focus")
            for _ in 0..<8 { pumpNativeEvents(); RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            assertReturnReleased("A focused Control Center search must retain ordinary typing keys")
            center.makeFirstResponder(nil)
            for _ in 0..<8 { pumpNativeEvents(); RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            store.requestErrors.removeValue(forKey: "dock-test")
            sendReturn(UInt32(kEventHotKeyPressed), key: UInt32(kVK_DownArrow))
            sendReturn(UInt32(kEventHotKeyReleased), key: UInt32(kVK_DownArrow))
            sendReturn(UInt32(kEventHotKeyPressed), key: UInt32(kVK_UpArrow))
            sendReturn(UInt32(kEventHotKeyReleased), key: UInt32(kVK_UpArrow))
            sendReturn(UInt32(kEventHotKeyPressed), key: key)
            sendReturn(UInt32(kEventHotKeyReleased), key: key)
            precondition(store.requestErrors["dock-test"] != nil,
                         "Return and keypad Enter must rearm after editing while the Control Center remains focused")
            store.requestErrors.removeValue(forKey: "dock-test")
            center.close()
            pumpNativeEvents()
        }
        let replyPanel = NSApp.windows.compactMap { $0 as? ReplyPanel }.first { $0 !== window }!
        let confirmation = NSAlert()
        confirmation.messageText = "Synthetic dangerous-mode confirmation"
        confirmation.addButton(withTitle: "Cancel")
        window.beginSheet(confirmation.window)
        for _ in 0..<8 { pumpNativeEvents(); RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        assertReturnReleased("Confirming an approval mode must not approve a waiting request in another window")
        sendReturn(UInt32(kEventHotKeyPressed), handled: false)
        sendReturn(UInt32(kEventHotKeyReleased), handled: false)
        precondition(store.requestErrors["dock-test"] == nil, "A confirmation sheet must isolate global approval keys")
        window.endSheet(confirmation.window)
        confirmation.window.orderOut(nil)
        store.floatingColorPickerSessionID = session.id
        for _ in 0..<8 {
            replyPanel.contentView?.layoutSubtreeIfNeeded()
            pumpNativeEvents()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        assertReturnReleased("Choosing a session color must release permission Return shortcuts")
        let pickerReturn = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: replyPanel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                            isARepeat: false, keyCode: 36)!
        _ = replyPanel.performKeyEquivalent(with: pickerReturn)
        precondition(store.requestErrors["dock-test"] == nil, "A color picker must suppress native default approval actions as well as global hotkeys")
        store.floatingColorPickerSessionID = nil
        store.setupVisible = true
        for _ in 0..<8 {
            replyPanel.contentView?.layoutSubtreeIfNeeded()
            pumpNativeEvents()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        assertReturnReleased("Agent setup must not let Return accidentally approve a floating request")
        _ = replyPanel.performKeyEquivalent(with: pickerReturn)
        precondition(store.requestErrors["dock-test"] == nil, "Setup must suppress native default approval actions")
        store.setupVisible = false
        for _ in 0..<8 {
            replyPanel.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let instructions = descendants(replyPanel.contentView!).compactMap { $0 as? NSTextField }.first {
            $0.placeholderString == "Denial instructions (optional)"
        }!
        NSApp.activate()
        pumpNativeEvents()
        replyPanel.makeKeyAndOrderFront(nil)
        precondition(replyPanel.makeFirstResponder(instructions))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        pumpNativeEvents()
        precondition(replyPanel.isKeyWindow, "The field-focus fixture must actually own keyboard focus")
        assertReturnReleased("Typing denial instructions must automatically release global Return")
        replyPanel.makeFirstResponder(nil)
        store.snooze("dock-test")
        let keyboardQuestion = try JSONSerialization.data(withJSONObject: [
            "type": "request", "sessionID": session.id,
            "request": ["id": "keyboard-question", "kind": "question", "title": "Keyboard choices",
                        "detail": "", "autoEligible": false, "questions": [
                            ["id": "choice", "text": "Pick an approach", "multiple": false, "allowFreeform": true,
                             "options": [["label": "A", "description": ""], ["label": "B", "description": ""]]]
                        ]]
        ])
        store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: keyboardQuestion))
        store.replyWorkspace.next(requestIDs: ["keyboard-question"])
        store.onAttentionChange?()
        sendReturn(UInt32(kEventHotKeyPressed), key: UInt32(kVK_DownArrow))
        sendReturn(UInt32(kEventHotKeyReleased), key: UInt32(kVK_DownArrow))
        sendReturn(UInt32(kEventHotKeyPressed))
        sendReturn(UInt32(kEventHotKeyReleased))
        precondition(store.replyWorkspace.drafts["keyboard-question"]?.selections["choice"] == ["B"],
                     "Arrows and Return must select the actual question option without answering a different request")
        sendReturn(UInt32(kEventHotKeyPressed), key: UInt32(kVK_UpArrow))
        sendReturn(UInt32(kEventHotKeyReleased), key: UInt32(kVK_UpArrow))
        for _ in 0..<8 {
            replyPanel.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        sendReturn(UInt32(kEventHotKeyPressed))
        sendReturn(UInt32(kEventHotKeyReleased))
        for _ in 0..<8 {
            replyPanel.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            pumpNativeEvents()
        }
        precondition((replyPanel.firstResponder as? NSTextView)?.isEditable == true && store.requestErrors["keyboard-question"] == nil,
                     "Choosing Other with Return must focus the real answer input")
        assertReturnReleased("Editing Other must restore ordinary keyboard input")
        let answerEditor = replyPanel.firstResponder as! NSTextView
        answerEditor.insertText("A custom keyboard answer", replacementRange: NSRange(location: NSNotFound, length: 0))
        pumpNativeEvents()
        let submitAnswer = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: replyPanel.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: UInt16(kVK_Return))!
        NSApp.sendEvent(submitAnswer)
        for _ in 0..<8 { pumpNativeEvents(); RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        precondition(store.requestErrors["keyboard-question"] != nil,
                     "Typing an answer then Return must dispatch that question, not insert a newline or do nothing")
        precondition(store.replyWorkspace.drafts["keyboard-question"]?.answers(for: store.activeFloatingRequest!.request)["choice"] == ["A custom keyboard answer"],
                     "Return must preserve the exact typed answer")
        let nextKeyboardRequest = try JSONSerialization.data(withJSONObject: [
            "type": "request", "sessionID": session.id,
            "request": ["id": "keyboard-next", "kind": "permission", "title": "Next decision",
                        "detail": "", "autoEligible": false, "questions": []]
        ])
        store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: nextKeyboardRequest))
        let keyboardResolved = try JSONSerialization.data(withJSONObject: [
            "type": "resolved", "sessionID": session.id, "requestID": "keyboard-question", "decision": "answer"
        ])
        store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: keyboardResolved))
        for _ in 0..<12 {
            replyPanel.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
            pumpNativeEvents()
        }
        precondition(store.activeFloatingRequest?.request.id == "keyboard-next", "Resolving an edited question must show the next request")
        sendReturn(UInt32(kEventHotKeyPressed), key: UInt32(kVK_DownArrow))
        sendReturn(UInt32(kEventHotKeyReleased), key: UInt32(kVK_DownArrow))
        sendReturn(UInt32(kEventHotKeyPressed))
        sendReturn(UInt32(kEventHotKeyReleased))
        precondition(store.requestErrors["keyboard-next"] != nil,
                     "Arrows and Return must rearm after the previous question's Other editor disappears")
        let nextResolved = try JSONSerialization.data(withJSONObject: [
            "type": "resolved", "sessionID": session.id, "requestID": "keyboard-next", "decision": "deny"
        ])
        store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: nextResolved))
        store.floatingEnabled = false
        assertReturnReleased("Hidden notifications must release their global keys")
        precondition(NSApp.dockTile.badgeLabel == String(previousWaiting + 1), "Snoozing a card must not erase its pending Dock count")
        store.automaticallySending.insert("dock-test")
        store.onAttentionChange?()
        precondition(NSApp.dockTile.badgeLabel == (previousWaiting == 0 ? nil : String(previousWaiting)), "Automatic replies must not flash a waiting badge")
        precondition(!replyPanel.becomesKeyOnlyIfNeeded && !replyPanel.hidesOnDeactivate,
                     "Clicking a card must permit keyboard focus without hiding it on app switches")
        center.performClose(nil)
        precondition(!store.centerVisible, "Closing the center must stop its illustration clock")
        precondition(!center.isVisible && !appDelegate.applicationShouldTerminateAfterLastWindowClosed(NSApp), "Closing the workspace must keep monitoring")
        NSApp.activate()
        pumpNativeEvents()
        _ = appDelegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        precondition(center.isVisible, "Dock reopening must restore a closed workspace")
        for _ in 0..<10 {
            pumpNativeEvents()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(store.centerVisible == (center.isVisible && center.occlusionState.contains(.visible)),
                     "Reopening must synchronize the illustration clock with the window's current occlusion state")
        precondition(center.appearance == nil && replyPanel.appearance == nil,
                     "Both windows must inherit Notify's app-wide appearance instead of pinning their own theme")
        for (mode, appearance): (AppearanceMode, NSAppearance.Name) in [(.dark, .darkAqua), (.light, .aqua)] {
            store.appearanceMode = mode
            for _ in 0..<10 {
                center.contentView?.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.025))
                pumpNativeEvents()
            }
            precondition(center.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance &&
                         replyPanel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance,
                         "Already-open windows must follow the user's Notify appearance choice without relaunching")
            let reopened = Store(directory: fixtureRoot, defaults: defaults)
            precondition(reopened.appearanceMode == mode, "The user's appearance choice must survive reopening")
            reopened.stop()
            let view = center.contentView!
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let background = bitmap.colorAt(x: bitmap.pixelsWide - 16, y: bitmap.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
            precondition(appearance == .darkAqua ? luminance(background) < 0.15 : luminance(background) > 0.6,
                         "Existing SwiftUI content must repaint after a system appearance change")
        }
        store.appearanceMode = .system
        precondition(NSApp.appearance == nil, "System must remove only Notify's appearance override")
        for _ in 0..<10 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
            pumpNativeEvents()
        }
        precondition(center.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ==
                     NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]),
                     "Returning to System must follow the current Mac appearance")
        for ownedWindow in NSApp.windows { ownedWindow.orderOut(nil) }
        print("Native notification color, Dock badge and reopen checks passed")
        if CommandLine.arguments.contains("--live-discovery") {
            let home = ProcessInfo.processInfo.environment["COPILOT_HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot")
            let found = try CopilotDiscovery.sessions(in: home.appendingPathComponent("session-state"), livePIDs: CopilotDiscovery.runningPIDs())
            let named = found.filter { !$0.title.isEmpty }
            precondition(!named.isEmpty, "Running chat titles should be discovered on this Mac")
            precondition(found.compactMap(\.metadataError).isEmpty, "Real saved metadata should decode")
            print("Live discovery: \(named.count) named chats out of \(found.count) running sessions")
        }
        window.contentView = nil
    }
}
