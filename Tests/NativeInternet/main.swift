import Foundation
import AppKit
import NotifyCore
import SwiftUI
import Vision

private final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func register(defaults registration: [String: Any]) { values.merge(registration) { existing, _ in existing } }
}

@main struct InternetChecks {
    static func precondition(_ condition: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
        Swift.precondition(condition, message, file: file, line: line)
    }

    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/internet-check-" + UUID().uuidString)
        let defaults = MemoryDefaults()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        defaults.set(true, forKey: "mobileEnabled")
        defaults.set(true, forKey: "internetEnabled")
        defaults.set(false, forKey: "autoYes")
        let resources = root.appendingPathComponent("resources")
        let scripts = resources.appendingPathComponent("mobile/src")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        for name in ["main.mjs", "remote-main.mjs"] {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "Tests/NativeInternet/helper.mjs"),
                                            to: scripts.appendingPathComponent(name))
        }
        let store = Store(directory: root.appendingPathComponent("store"), defaults: defaults, mobileResources: resources)
        defer { store.stop() }
        precondition(store.mobile.enabled && !store.internet.enabled, "Persisted LAN/internet preferences must not authorize internet access")
        store.internet.start()
        precondition(!store.internet.starting && store.internet.internetStatus == nil)
        for origin in ["http://example.com", "https://user@example.com", "https://example.com/", "https://example.com/path",
                       "https://example.com?x", "https://example.com#x", " https://example.com", "https://example.com\n",
                       "https://example.com:", "https://example.com:0", "https://example.com:65536", "https://exa%mple.com"] {
            precondition(!MobileConnection.isValidInternetOrigin(origin), "Must reject rather than normalize: \(origin)")
        }
        for origin in ["https://example.com", "https://example.com:443", "https://localhost:9443", "https://[::1]:9443"] {
            precondition(MobileConnection.isValidInternetOrigin(origin))
        }
        store.internet.setInternetOrigin("https://example.com/")
        store.internet.setEnabled(true)
        precondition(!store.internet.enabled && store.internet.error != nil)
        store.internet.setInternetOrigin("https://example.com")
        let missing = MobileConnection(directory: root.appendingPathComponent("missing"), defaults: defaults,
                                       resources: root, transport: .internet)
        missing.setEnabled(true)
        precondition(missing.error != nil && missing.internetStatus == nil && !missing.starting,
                     "Missing bundled helper must fail explicitly, never appear connected")
        missing.setEnabled(false)

        func wait(_ predicate: () throws -> Bool, line: UInt = #line) rethrows {
            let deadline = Date().addingTimeInterval(8)
            while try !predicate(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            precondition(try predicate(), "Internet fixture failed at line \(line): \(store.internet.error ?? store.error ?? "timeout")")
        }
        func events(_ connection: MobileConnection) throws -> [[String: Any]] {
            let directory = store.directory.appendingPathComponent(connection.transport == .internet ? "remote-mobile" : "mobile")
            guard let text = try? String(contentsOf: directory.appendingPathComponent("events.jsonl"), encoding: .utf8) else { return [] }
            return try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        }
        func emit(_ connection: MobileConnection, _ values: [[String: Any]]) throws {
            let directory = store.directory.appendingPathComponent(connection.transport == .internet ? "remote-mobile" : "mobile")
            try JSONSerialization.data(withJSONObject: values).write(to: directory.appendingPathComponent("inbox.json"), options: .atomic)
            connection.invite()
            wait { !FileManager.default.fileExists(atPath: directory.appendingPathComponent("inbox.json").path) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        func packet(_ value: [String: Any]) throws {
            var value = value
            value["sessionID"] = "fixture"
            store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: JSONSerialization.data(withJSONObject: value)))
        }
        func remoteStatus(_ state: String) -> [String: Any] {
            ["type": "status", "status": ["state": state, "url": "https://example.com",
                "devices": state == "connected" ? [["id": "remote", "name": "Remote fixture", "online": true, "pushEnabled": false]] : [],
                "pendingPairingIDs": []]]
        }
        var ready = false
        store.server.onReady = { ready = true }
        try store.server.start()
        wait { ready }
        store.mobile.start()
        wait { store.registry.sessions["fixture"]?.connected == true }
        try packet(["type": "capabilities", "steering": true])
        for id in ["q1", "q2", "q3", "q4"] {
            try packet(["type": "request", "request": ["id": id, "kind": "permission", "title": "Allow?", "detail": "", "autoEligible": false, "questions": []]])
        }
        store.internet.setEnabled(true)
        wait { store.internet.internetStatus?.state == .connecting }
        precondition(!store.internet.canReceiveCommands)
        precondition(try events(store.internet).filter { $0["type"] as? String == "snapshot" }.isEmpty,
                     "Connecting must not publish private snapshots")
        try emit(store.internet, [remoteStatus("connected")])
        wait { store.internet.canReceiveCommands }
        try wait { try events(store.internet).contains { $0["type"] as? String == "snapshot" } }
        let start = try events(store.internet).first!
        precondition(start["origin"] as? String == "https://example.com" &&
                     start["directory"] as? String == store.directory.appendingPathComponent("remote-mobile").path)
        let lanItems = store.phoneSnapshot()
        let internetItems = store.phoneSnapshot(from: store.internet)
        precondition(lanItems.first!.ticket != internetItems.first!.ticket)

        func reply(_ id: String, _ requestID: String, _ ticket: String, _ connection: MobileConnection) throws {
            let value: [String: Any] = ["id": id, "sessionID": "fixture", "requestID": requestID, "ticket": ticket, "decision": "allow"]
            store.replyFromPhone(try JSONDecoder().decode(MobileReply.self, from: JSONSerialization.data(withJSONObject: value)), from: connection)
        }
        func result(_ connection: MobileConnection, _ id: String, _ ok: Bool) throws -> Bool {
            try events(connection).contains { $0["type"] as? String == "result" && $0["id"] as? String == id && $0["ok"] as? Bool == ok }
        }
        let lanQ1 = lanItems.first { $0.request.id == "q1" }!
        let remoteQ1 = internetItems.first { $0.request.id == "q1" }!
        try reply("forged", "q1", lanQ1.ticket, store.internet)
        try wait { try result(store.internet, "forged", false) }
        precondition(!store.sending.contains("q1"), "LAN ticket must not authorize internet answer")
        try reply("shared-id", "q1", remoteQ1.ticket, store.internet)
        precondition(store.sending.contains("q1"))
        precondition(try !result(store.internet, "shared-id", true), "Socket write is not acknowledgment")
        let lanQ2 = lanItems.first { $0.request.id == "q2" }!
        try reply("shared-id", "q2", lanQ2.ticket, store.mobile)
        precondition(store.sending.contains("q2"), "IDs are scoped to originating transport")
        try packet(["type": "resolved", "requestID": "q1", "decision": "allow"])
        try wait { try result(store.internet, "shared-id", true) }
        precondition(try !result(store.mobile, "shared-id", true), "ACK must not cross transports")
        try packet(["type": "resolved", "requestID": "q2", "decision": "deny"])
        try wait { try result(store.mobile, "shared-id", false) }

        func control(_ connection: MobileConnection, id: String = UUID().uuidString, ticket: String? = nil) throws -> MobileControl {
            let overview = try JSONSerialization.jsonObject(with: store.phoneWorkspaceSnapshot(watching: [], from: connection).first!) as! [String: Any]
            let row = (overview["sessions"] as! [[String: Any]]).first!
            return try JSONDecoder().decode(MobileControl.self, from: JSONSerialization.data(withJSONObject: [
                "id": id, "sessionID": "fixture", "ticket": ticket ?? row["ticket"]!, "action": "queue", "text": "Fixture only"
            ]))
        }
        let lanControl = try control(store.mobile)
        let forgedControl = try control(store.internet, ticket: lanControl.ticket)
        store.controlFromPhone(forgedControl, from: store.internet)
        try wait { try events(store.internet).contains { $0["id"] as? String == forgedControl.id && $0["ok"] as? Bool == false } }
        let remoteControl = try control(store.internet)
        store.controlFromPhone(remoteControl, from: store.internet)
        let acceptedReceipt = store.steeringWorkspace.history["fixture"]!.last!
        try packet(["type": "control_status", "commandID": acceptedReceipt.id, "status": "received"])
        try wait { try events(store.internet).contains { $0["id"] as? String == remoteControl.id && $0["ok"] as? Bool == true } }
        precondition(try !events(store.mobile).contains { $0["id"] as? String == remoteControl.id })
        let sameIDLAN = try control(store.mobile, id: remoteControl.id)
        store.controlFromPhone(sameIDLAN, from: store.mobile)
        let lanReceipt = store.steeringWorkspace.history["fixture"]!.last!
        precondition(lanReceipt.id != acceptedReceipt.id && lanReceipt.status == "sending")
        try packet(["type": "control_status", "commandID": lanReceipt.id, "status": "received"])
        try wait { try events(store.mobile).contains { $0["id"] as? String == remoteControl.id && $0["ok"] as? Bool == true } }
        let uncertainControl = try control(store.internet)
        store.controlFromPhone(uncertainControl, from: store.internet)
        let receipt = store.steeringWorkspace.history["fixture"]!.last!
        precondition(receipt.status == "sending")
        let lanQ4 = store.phoneSnapshot().first { $0.request.id == "q4" }!
        try reply("lan-survives", "q4", lanQ4.ticket, store.mobile)
        let remoteQ3 = store.phoneSnapshot(from: store.internet).first { $0.request.id == "q3" }!
        try reply("uncertain", "q3", remoteQ3.ticket, store.internet)
        try emit(store.internet, [remoteStatus("paused")])
        precondition(!store.internet.canReceiveCommands)
        precondition(store.steeringWorkspace.receipt(sessionID: "fixture", commandID: receipt.id)?.status == "unknown")
        precondition(store.requestErrors["q3"]?.contains("uncertain") == true)
        precondition(store.mobile.canReceiveCommands, "Remote disconnect must not disable LAN")
        try packet(["type": "resolved", "requestID": "q4", "decision": "allow"])
        try wait { try result(store.mobile, "lan-survives", true) }
        try emit(store.internet, [remoteStatus("connected")])
        precondition(store.phoneSnapshot(from: store.internet).first { $0.request.id == "q3" }!.ticket != remoteQ3.ticket)
        try packet(["type": "resolved", "requestID": "q3", "decision": "allow"])
        try packet(["type": "control_status", "commandID": receipt.id, "status": "queued"])
        precondition(try !result(store.internet, "uncertain", true), "Disconnected commands must never replay results after reconnect")
        precondition(try !events(store.internet).contains { $0["id"] as? String == uncertainControl.id }, "Late control ACK must not reach new channel")
        try packet(["type": "capabilities", "sessionAutoYes": true, "steering": false])
        func policyRow(_ sessionID: String = "fixture") throws -> [String: Any] {
            let overview = try JSONSerialization.jsonObject(with: store.phoneWorkspaceSnapshot(watching: [], from: store.internet).first!) as! [String: Any]
            return (overview["sessions"] as! [[String: Any]]).first { $0["id"] as? String == sessionID }!
        }
        func policyControl(_ enabled: Bool, sessionID: String = "fixture") throws -> MobileControl {
            let row = try policyRow(sessionID)
            var value: [String: Any] = [
                "id": UUID().uuidString, "sessionID": sessionID, "ticket": row["ticket"]!,
                "action": "dangerous_auto_yes", "text": "", "enabled": enabled,
                "policyTicket": (row["dangerousAutoYes"] as! [String: Any])["ticket"]!,
                "offTicket": (row["dangerousAutoYes"] as! [String: Any])["offTicket"]!
            ]
            if !enabled {
                value["id"] = value["offTicket"]
            }
            return try JSONDecoder().decode(MobileControl.self, from: JSONSerialization.data(withJSONObject: value))
        }
        func policyResult(_ control: MobileControl) throws -> [String: Any]? {
            try events(store.internet).last { $0["type"] as? String == "control_result" && $0["id"] as? String == control.id }
        }
        let reviewedBeforeOff = try policyControl(true)
        store.setSessionDangerousAutoYes("fixture", enabled: false)
        store.controlFromPhone(reviewedBeforeOff, from: store.internet)
        try wait { try policyResult(reviewedBeforeOff)?["ok"] as? Bool == false }
        precondition(store.automation.activeIDs.isEmpty, "Newer Mac Off must invalidate delayed phone enable")
        let reviewedBeforeStop = try policyControl(true)
        try packet(["type": "error", "text": "Synthetic safety reset while already off"])
        store.controlFromPhone(reviewedBeforeStop, from: store.internet)
        try wait { try policyResult(reviewedBeforeStop)?["ok"] as? Bool == false }
        precondition(store.automation.activeIDs.isEmpty, "Safety reset must invalidate queued enables even when already off")
        store.steeringWorkspace.setDraft("Preserve native draft", sessionID: "fixture")
        let reviewedOffBeforeOn = try policyControl(false)
        let policyOn = try policyControl(true)
        store.controlFromPhone(policyOn, from: store.internet)
        try wait { try policyResult(policyOn)?["status"] as? String == "applied" }
        precondition(store.automation.dangerous.contains("fixture"), "Phone must control the existing native policy without steering")
        precondition(try policyRow()["ticket"] as? String == policyOn.ticket, "Policy change must preserve workspace tickets")
        precondition(store.steeringWorkspace.draft(sessionID: "fixture") == "Preserve native draft")
        store.controlFromPhone(reviewedOffBeforeOn, from: store.internet)
        try wait { try policyResult(reviewedOffBeforeOn)?["ok"] as? Bool == true }
        precondition(store.automation.activeIDs.isEmpty, "Direct Off must supersede an enable without waiting for its new ticket")
        let resumedOn = try policyControl(true)
        store.controlFromPhone(resumedOn, from: store.internet)
        try wait { try policyResult(resumedOn)?["ok"] as? Bool == true }
        try emit(store.internet, [remoteStatus("paused")])
        precondition(store.automation.dangerous.contains("fixture"), "PHONE disconnect must retain enabled policy")
        try emit(store.internet, [remoteStatus("connected")])
        for (id, kind, eligible) in [("eligible-tool", "permission", true), ("ineligible-tool", "permission", false),
                                     ("manual-question", "question", true)] {
            try packet(["type": "request", "request": ["id": id, "kind": kind, "title": "Synthetic only", "detail": "",
                "autoEligible": false, "sessionAutoEligible": eligible,
                "questions": kind == "question" ? [["id": "q", "text": "Choose", "multiple": false, "allowFreeform": true, "options": []]] : []]])
        }
        precondition(store.sending.contains("eligible-tool") && !store.sending.contains("ineligible-tool") &&
            !store.sending.contains("manual-question"), "Future permissions must use native eligibility; questions remain manual")
        try packet(["type": "resolved", "requestID": "eligible-tool", "decision": "allow"])
        let offAudit = try policyControl(false)
        let history = store.directory.appendingPathComponent("history.json")
        try FileManager.default.removeItem(at: history)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: false)
        store.controlFromPhone(offAudit, from: store.internet)
        try wait { try policyResult(offAudit)?["ok"] as? Bool == false }
        precondition(store.automation.activeIDs.isEmpty, "Off must disable before its audit write")
        let offAck = try policyResult(offAudit)!
        precondition((offAck["dangerousAutoYes"] as? [String: Any])?["enabled"] as? Bool == false &&
            (offAck["error"] as? String)?.contains("audit") == true, "Failed audit must report actual Off and its error")
        let failedOn = try policyControl(true)
        store.controlFromPhone(failedOn, from: store.internet)
        try wait { try policyResult(failedOn)?["ok"] as? Bool == false }
        precondition(store.automation.activeIDs.isEmpty, "Failed enable audit must never enable")
        try FileManager.default.removeItem(at: history)
        try packet(["type": "request", "request": ["id": "waiting-tool", "kind": "permission", "title": "Synthetic only",
            "detail": "", "autoEligible": false, "sessionAutoEligible": true, "questions": []]])
        precondition(!store.sending.contains("waiting-tool"))
        let waitingOn = try policyControl(true)
        store.controlFromPhone(waitingOn, from: store.internet)
        try wait { try policyResult(waitingOn)?["ok"] as? Bool == true }
        precondition(store.sending.contains("waiting-tool") && !store.sending.contains("manual-question") &&
            !store.sending.contains("ineligible-tool"), "Phone enable dispatches waiting eligible tools through native approval only")
        try packet(["type": "resolved", "requestID": "waiting-tool", "decision": "allow"])
        try packet(["type": "capabilities", "sessionAutoYes": false])
        precondition(store.automation.activeIDs.isEmpty, "Capability loss must retain the native reset")
        try packet(["type": "capabilities", "sessionAutoYes": true, "steering": true])
        store.setSessionDangerousAutoYes("fixture", enabled: true)
        _ = store.steer("fixture", action: "stop")
        precondition(store.automation.activeIDs.isEmpty, "Stop must retain the native reset")
        store.setSessionDangerousAutoYes("fixture", enabled: true)
        try packet(["type": "error", "text": "Synthetic failed runtime acknowledgment"])
        precondition(store.automation.activeIDs.isEmpty, "Failed runtime acknowledgment must reset policy")
        store.setSessionDangerousAutoYes("fixture", enabled: true)
        for value: [String: Any] in [
            ["type": "hello", "sessionID": "no-socket", "agent": "copilot", "cwd": "/synthetic"],
            ["type": "capabilities", "sessionID": "no-socket", "sessionAutoYes": true],
            ["type": "request", "sessionID": "no-socket", "request": ["id": "cannot-dispatch", "kind": "permission",
                "title": "Synthetic disconnected transport", "detail": "", "autoEligible": false, "sessionAutoEligible": true, "questions": []]]
        ] {
            store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: JSONSerialization.data(withJSONObject: value)))
        }
        let failedDispatch = try policyControl(true, sessionID: "no-socket")
        store.controlFromPhone(failedDispatch, from: store.internet)
        try wait { try policyResult(failedDispatch)?["ok"] as? Bool == false }
        precondition(!store.automation.dangerous.contains("no-socket") && store.automation.dangerous.contains("fixture"),
            "Dispatch failure must reset exactly the failed session, not another enabled session")
        precondition((try policyResult(failedDispatch)?["dangerousAutoYes"] as? [String: Any])?["enabled"] as? Bool == false)
        store.server.onDisconnect("fixture")
        precondition(store.automation.activeIDs.isEmpty, "Provider disconnect must retain the native reset")
        try packet(["type": "hello", "agent": "copilot", "cwd": "/fixture"])
        try packet(["type": "capabilities", "sessionAutoYes": true, "steering": true])
        try emit(store.internet, [["type": "status", "status": [
            "state": "pairing", "url": "https://example.com", "devices": [], "pendingPairingIDs": ["pair"]
        ]], ["type": "pairing", "id": "pair", "name": "Verified fixture", "code": "123456"]])
        precondition(store.internet.pairing != nil && !store.internet.canReceiveCommands)
        let unverifiedPairing = store.internet.pairing
        store.internet.confirmPairing(true)
        precondition(try !events(store.internet).contains { $0["type"] as? String == "pair" },
                     "A short comparison code must not authorize remote pairing")
        let fullVerification = (Data([4]) + Data(repeating: 1, count: 64)).base64EncodedString()
        try emit(store.internet, [["type": "pairing", "id": "pair", "name": "Verified fixture",
                                  "verificationData": fullVerification]])
        precondition(store.internet.pairing?.verificationData == fullVerification, "Full pairing proof must never be truncated")
        store.internet.confirmPairing(true, expected: unverifiedPairing)
        precondition(try !events(store.internet).contains { $0["type"] as? String == "pair" },
                     "A replaced pairing prompt must not approve a different displayed identity")
        store.internet.confirmPairing(true, expected: store.internet.pairing)
        try wait { try events(store.internet).contains { $0["type"] as? String == "pair" && $0["allow"] as? Bool == true &&
            $0["verificationData"] as? String == fullVerification } }
        try emit(store.internet, [remoteStatus("connected")])
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        precondition(!store.internet.canReceiveCommands, "Waking must not reuse a pre-sleep authenticated channel")
        try emit(store.internet, [remoteStatus("connected")])
        precondition(store.internet.canReceiveCommands)
        store.internet.setEnabled(false)
        for invalidStatus: [String: Any] in [
            ["state": "connected", "url": "https://example.com", "devices": [], "pendingPairingIDs": []],
            ["state": "pairing", "url": "https://other.example", "devices": [], "pendingPairingIDs": []],
            ["state": "pairing", "url": "https://example.com", "devices": [], "pendingPairingIDs": [],
             "setupURL": "https://user@example.com/enroll"]
        ] {
            store.internet.setEnabled(true)
            wait { store.internet.internetStatus?.state == .connecting }
            try emit(store.internet, [["type": "status", "status": invalidStatus]])
            wait { store.internet.error != nil }
            precondition(!store.internet.canReceiveCommands && store.internet.internetStatus == nil,
                         "False connected state, origin substitution and credentialed setup URLs must fail closed")
            store.internet.setEnabled(false)
        }
        let restarted = Store(directory: root.appendingPathComponent("restarted"), defaults: defaults, mobileResources: resources)
        precondition(!restarted.internet.enabled)
        restarted.stop()
        let recoveryDirectory = root.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let originalIdentity = Data("synthetic saved account and phone trust".utf8)
        let identityFile = recoveryDirectory.appendingPathComponent("identity.json")
        try originalIdentity.write(to: identityFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identityFile.path)
        try Data().write(to: recoveryDirectory.appendingPathComponent("delay-stop"))
        let recovery = MobileConnection(directory: recoveryDirectory, defaults: defaults, resources: resources, transport: .internet)
        defer { recovery.stop() }
        recovery.setEnabled(true)
        wait { recovery.internetStatus != nil }
        recovery.startFreshInternetSetup()
        precondition(recovery.error != nil && recovery.internetBackupURL == nil)
        precondition(try Data(contentsOf: identityFile) == originalIdentity, "Enabled recovery must not alter saved trust")
        recovery.setEnabled(false)
        precondition(!recovery.canStartFreshInternetSetup, "Stopping is not stopped: the old helper may still write")
        recovery.startFreshInternetSetup()
        precondition(recovery.error != nil && recovery.internetBackupURL == nil)
        wait { recovery.canStartFreshInternetSetup }
        recovery.startFreshInternetSetup()
        precondition(recovery.error == nil && !recovery.enabled && recovery.internetStatus == nil)
        let backup = recovery.internetBackupURL!
        precondition(backup.deletingLastPathComponent() == recoveryDirectory.deletingLastPathComponent())
        precondition(try Data(contentsOf: backup.appendingPathComponent("identity.json")) == originalIdentity)
        precondition((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        precondition((try FileManager.default.attributesOfItem(atPath: backup.appendingPathComponent("identity.json").path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        precondition(!FileManager.default.fileExists(atPath: recoveryDirectory.path))
        precondition(store.mobile.canReceiveCommands, "Internet recovery must not stop LAN or the synthetic terminal")
        recovery.setEnabled(true)
        wait { recovery.internetStatus != nil }
        precondition(!FileManager.default.fileExists(atPath: identityFile.path), "Fresh startup must not inherit the previous identity")
        precondition(try Data(contentsOf: backup.appendingPathComponent("identity.json")) == originalIdentity)
        recovery.setEnabled(false)
        wait { recovery.canStartFreshInternetSetup }

        let linkedDirectory = root.appendingPathComponent("linked-recovery")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: backup)
        let linkedRecovery = MobileConnection(directory: linkedDirectory, defaults: defaults, resources: resources, transport: .internet)
        linkedRecovery.startFreshInternetSetup()
        precondition(linkedRecovery.error != nil && linkedRecovery.internetBackupURL == nil)
        precondition(try Data(contentsOf: backup.appendingPathComponent("identity.json")) == originalIdentity,
                     "A symlink must never redirect recovery to another setup")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recoveryDirectory.path)
        recovery.startFreshInternetSetup()
        precondition(recovery.error != nil && FileManager.default.fileExists(atPath: recoveryDirectory.path),
                     "Unsafe permissions must fail without moving the original")
        let lanRecovery = MobileConnection(directory: backup, defaults: defaults, resources: resources, transport: .lan)
        lanRecovery.startFreshInternetSetup()
        precondition(lanRecovery.error != nil && FileManager.default.fileExists(atPath: backup.path),
                     "The internet recovery operation must never archive LAN state")
        if CommandLine.arguments.contains("--recovery-ui") {
            let uiDirectory = root.appendingPathComponent("recovery-ui")
            try FileManager.default.createDirectory(at: uiDirectory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try originalIdentity.write(to: uiDirectory.appendingPathComponent("identity.json"))
            let uiConnection = MobileConnection(directory: uiDirectory, defaults: defaults, resources: resources, transport: .internet)
            try recoveryUI(uiConnection, directory: uiDirectory)
        }
        store.setSessionDangerousAutoYes("fixture", enabled: true)
        precondition(store.automation.dangerous.contains("fixture"))
        store.stop()
        precondition(store.automation.activeIDs.isEmpty, "App shutdown must retain the native reset")
        print("Native internet checks passed: isolated commands, Dangerous Auto-yes policy/ACK/races/resets, safe recovery/backup; no installed-app changes or Keychain access.")
    }

    @MainActor static func recoveryUI(_ connection: MobileConnection, directory: URL) throws {
        let previousApplication = NSWorkspace.shared.frontmostApplication
        defer { previousApplication?.activate(options: []) }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let output = URL(fileURLWithPath: ".build/internet-recovery-captures", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func requireUI(_ condition: Bool, _ message: String) throws {
            guard condition else {
                throw NSError(domain: "RecoveryUI", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func pump() {
            let deadline = Date().addingTimeInterval(0.3)
            while Date() < deadline {
                while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
        }
        func click(_ title: String, in view: NSView) throws {
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let recognition = VNRecognizeTextRequest()
            recognition.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([recognition])
            guard let item = recognition.results?.first(where: { $0.topCandidates(1).first?.string == title }),
                  let window = view.window else {
                throw NSError(domain: "RecoveryUI", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing visible button: \(title)"])
            }
            let point = view.convert(NSPoint(x: item.boundingBox.midX * view.bounds.width,
                y: (view.isFlipped ? 1 - item.boundingBox.midY : item.boundingBox.midY) * view.bounds.height), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!, atStart: false)
            }
            pump()
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            let host = NSHostingView(rootView: InternetSettingsView(internet: connection)
                .padding(24).frame(width: 560, height: 680, alignment: .topLeading).background(Palette.surface))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 560, height: 680)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
            let image = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: image)
            let recognition = VNRecognizeTextRequest()
            recognition.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image.cgImage!, options: [:]).perform([recognition])
            let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            guard text.contains("Start fresh internet setup") else {
                throw NSError(domain: "RecoveryUI", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Recovery must be reachable while internet is disabled. Rendered: \(text)"
                ])
            }
            try image.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("recovery-\(name).png"))
            if name == "dark" {
                window.title = "Notify recovery check - synthetic data only"
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                pump()
                try click("Start fresh internet setup", in: host)
                try requireUI(FileManager.default.fileExists(atPath: directory.path) && connection.internetBackupURL == nil,
                              "Opening confirmation must not move saved state")
                guard let sheet = window.attachedSheet, let sheetView = sheet.contentView else {
                    throw NSError(domain: "RecoveryUI", code: 3, userInfo: [NSLocalizedDescriptionKey: "Recovery must require a native confirmation"])
                }
                let confirmation = sheetView.bitmapImageRepForCachingDisplay(in: sheetView.bounds)!
                sheetView.cacheDisplay(in: sheetView.bounds, to: confirmation)
                try confirmation.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("recovery-confirmation.png"))
                try click("Cancel", in: sheetView)
                try requireUI(FileManager.default.fileExists(atPath: directory.path) && connection.internetBackupURL == nil,
                              "Cancel must preserve the original setup")
                try click("Start fresh internet setup", in: host)
                guard let confirmedSheet = window.attachedSheet?.contentView else {
                    throw NSError(domain: "RecoveryUI", code: 5, userInfo: [NSLocalizedDescriptionKey: "Missing repeated confirmation"])
                }
                try click("Back up and start fresh", in: confirmedSheet)
                try requireUI(connection.internetBackupURL != nil && !FileManager.default.fileExists(atPath: directory.path) &&
                              !connection.enabled, "Confirmed recovery must archive only the synthetic setup and stay disabled")
            }
        }
    }
}
