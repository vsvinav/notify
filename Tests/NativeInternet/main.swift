import Foundation
import AppKit
import NotifyCore

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

    static func main() throws {
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
        print("Native internet checks passed: opt-in, strict origins, helper errors, isolated tickets/IDs, exact ACKs, disconnect uncertainty; no app launch or Keychain access.")
    }
}
