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
        var launchedSessions: [SessionRecord] = []
        var owner: Int32?
        var pauseOwner = false
        var ownerContinuation: CheckedContinuation<Int32?, Error>?
        var launchContinuation: CheckedContinuation<Void, Error>?
        let terminal = SessionTerminal(unavailable: { _ in nil }, owner: { _ in
            if pauseOwner { return try await withCheckedThrowingContinuation { ownerContinuation = $0 } }
            return owner
        },
            launch: { session in
                launchedSessions.append(session)
                try await withCheckedThrowingContinuation { launchContinuation = $0 }
            }, focus: { _ in preconditionFailure("Synthetic phone resume must never focus a terminal") },
            connectionTimeout: 0.6)
        let store = Store(directory: root.appendingPathComponent("store"), defaults: defaults, mobileResources: resources, terminal: terminal)
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
        let parityOverview = try JSONSerialization.jsonObject(with: store.phoneWorkspaceSnapshot(watching: [], from: store.internet)[0]) as! [String: Any]
        let parityRow = (parityOverview["sessions"] as! [[String: Any]]).first { $0["id"] as? String == "fixture" }!
        precondition(parityRow["sessionActions"] is [String: Any],
                     "Actual Store workspace must expose native-authoritative session appearance/order/removal/resume metadata")
        func row(_ id: String, _ connection: MobileConnection? = nil) throws -> [String: Any] {
            let overview = try JSONSerialization.jsonObject(with: store.phoneWorkspaceSnapshot(watching: [], from: connection ?? store.internet)[0]) as! [String: Any]
            return (overview["sessions"] as! [[String: Any]]).first { $0["id"] as? String == id }!
        }
        func sessionCommand(_ id: String, _ action: String, extra: [String: Any] = [:],
                            connection: MobileConnection? = nil) throws -> [String: Any] {
            let current = try row(id, connection)
            return ["type": "control", "id": UUID().uuidString, "sessionID": id, "ticket": current["ticket"]!,
                "action": action, "text": "", "sessionTicket": (current["sessionActions"] as! [String: Any])["ticket"]!]
                .merging(extra) { _, value in value }
        }
        func sessionResult(_ command: [String: Any], status: String, connection: MobileConnection? = nil) throws {
            try wait { try events(connection ?? store.internet).contains {
                $0["type"] as? String == "control_result" && $0["id"] as? String == command["id"] as? String && $0["status"] as? String == status
            } }
        }
        let originalColor = store.appearance.color(for: store.registry.sessions["fixture"]!)
        let colorCommand = try sessionCommand("fixture", "set_session_color", extra: ["rgb": 0x010203])
        try emit(store.internet, [colorCommand])
        try sessionResult(colorCommand, status: "color_saved")
        precondition(try SessionAppearance.load(from: store.directory).color(for: store.registry.sessions["fixture"]!) == 0x010203)
        let coloredRow = try row("fixture")
        precondition(coloredRow["ticket"] as? String == parityRow["ticket"] as? String, "Color must not change runtime/management authority")
        let colorMetadata = coloredRow["sessionActions"] as! [String: Any]
        precondition(colorMetadata["rgb"] as? Int == 0x010203 && colorMetadata["overridden"] as? Bool == true)
        precondition((colorMetadata["colors"] as! [[String: Any]]).count == 20, "Use the actual native palette")
        let reset = try sessionCommand("fixture", "reset_session_color")
        try emit(store.internet, [reset]); try sessionResult(reset, status: "color_reset")
        precondition(store.appearance.color(for: store.registry.sessions["fixture"]!) == originalColor)
        let failedColor = try sessionCommand("fixture", "set_session_color", extra: ["rgb": 0x987654])
        let colorPath = store.directory.appendingPathComponent("session-colors.json")
        try FileManager.default.removeItem(at: colorPath)
        try FileManager.default.createDirectory(at: colorPath, withIntermediateDirectories: false)
        try emit(store.internet, [failedColor]); try sessionResult(failedColor, status: "failed")
        precondition(store.appearance.color(for: store.registry.sessions["fixture"]!) == originalColor, "Failed persistence must not change visible color")
        try FileManager.default.removeItem(at: colorPath)

        let savedID = "11111111-1111-4111-8111-111111111111"
        let peerID = "22222222-2222-4222-8222-222222222222"
        let savedHistory = root.appendingPathComponent("synthetic-history")
        for id in [savedID, peerID] {
            let directory = savedHistory.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("name: Synthetic saved chat\ncwd: \(root.path)\n".utf8).write(to: directory.appendingPathComponent("workspace.yaml"))
        }
        let catalog = try CopilotDiscovery.catalog(in: savedHistory, livePIDs: [])
        store.updateCatalog(catalog)
        let canonicalOrder = store.orderedSessions.map { $0.sourceSessionID ?? $0.id }
        for message: [String: Any] in [
            ["type": "hello", "sessionID": "z-peer-alias", "agent": "copilot", "cwd": root.path],
            ["type": "metadata", "sessionID": "z-peer-alias", "title": "Peer alias", "sourceSessionID": peerID]
        ] {
            store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: JSONSerialization.data(withJSONObject: message)))
        }
        precondition(store.orderedSessions.map { $0.sourceSessionID ?? $0.id } == canonicalOrder,
                     "Reconnect aliases must retain canonical order even before the first manual move")
        store.server.onDisconnect("z-peer-alias")
        _ = store.removeDisconnected("z-peer-alias")
        store.updateCatalog(catalog)
        let move = try sessionCommand(savedID, "move_session", extra: ["targetID": peerID,
            "targetTicket": (try row(peerID)["sessionActions"] as! [String: Any])["ticket"]!])
        try emit(store.internet, [move]); try sessionResult(move, status: "session_moved")
        precondition(store.sessionOrder.prefix(2) == [peerID, savedID])
        let rejectedMove = try sessionCommand(savedID, "move_session", extra: ["targetID": "fixture",
            "targetTicket": (try row("fixture")["sessionActions"] as! [String: Any])["ticket"]!])
        try emit(store.internet, [rejectedMove]); try sessionResult(rejectedMove, status: "failed")
        let remove = try sessionCommand(peerID, "remove_session")
        store.select("fixture")
        try emit(store.internet, [remove]); try sessionResult(remove, status: "session_removed")
        precondition(store.registry.sessions[peerID] == nil && store.selectedID == "fixture")
        precondition(FileManager.default.fileExists(atPath: savedHistory.appendingPathComponent(peerID + "/workspace.yaml").path))
        store.updateCatalog(catalog)
        precondition(store.registry.sessions[peerID]?.isSaved == true, "Discovery may restore an unchanged history row")
        let reconnectedRemove = try sessionCommand(peerID, "remove_session")
        store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: JSONSerialization.data(withJSONObject: [
            "type": "hello", "sessionID": peerID, "agent": "copilot", "cwd": root.path])))
        try emit(store.internet, [reconnectedRemove]); try sessionResult(reconnectedRemove, status: "failed")
        precondition(store.registry.sessions[peerID]?.connected == true)
        let savedColor = try sessionCommand(savedID, "set_session_color", extra: ["rgb": 0x234567])
        try emit(store.internet, [savedColor]); try sessionResult(savedColor, status: "color_saved")
        let savedResumeAuthority = (try row(savedID)["sessionActions"] as! [String: Any])["resumeAuthority"] as! [String: Any]
        let resume = try sessionCommand(savedID, "resume_session")
        let secondPhone = try sessionCommand(savedID, "resume_session", connection: store.mobile)
        try emit(store.internet, [resume])
        wait { launchedSessions.count == 1 && launchContinuation != nil }
        precondition(launchedSessions[0].id == savedID && launchedSessions[0].cwd == root.path && launchedSessions[0].agent == "copilot")
        try emit(store.mobile, [secondPhone]); try sessionResult(secondPhone, status: "failed", connection: store.mobile)
        precondition(launchedSessions.count == 1, "Two phones must not duplicate an in-flight launch")
        precondition((try row(savedID)["sessionActions"] as! [String: Any])["resumeStatus"] as? String == "launching")
        launchContinuation?.resume(); launchContinuation = nil
        try sessionResult(resume, status: "launched")
        precondition(store.registry.sessions[savedID]?.connected == false, "AppleScript completion is not agent connection")
        wait { store.resumeResults["copilot:" + savedID]?.status == "unconfirmed" }
        let repeatResume = try sessionCommand(savedID, "resume_session")
        try emit(store.internet, [repeatResume]); try sessionResult(repeatResume, status: "failed")
        precondition(launchedSessions.count == 1, "An unconfirmed launch must not replay")
        for message: [String: Any] in [
            ["type": "hello", "sessionID": "resumed-alias", "agent": "copilot", "cwd": root.path],
            ["type": "metadata", "sessionID": "resumed-alias", "title": "Resumed", "sourceSessionID": savedID]
        ] {
            store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: JSONSerialization.data(withJSONObject: message)))
        }
        let aliasMetadata = try row("resumed-alias")["sessionActions"] as! [String: Any]
        precondition(aliasMetadata["resumeStatus"] as? String == "connected" && aliasMetadata["sourceID"] as? String == savedID)
        precondition(aliasMetadata["rgb"] as? Int == 0x234567 && store.sessionOrder.contains(savedID) && !store.sessionOrder.contains("resumed-alias"),
                     "A matching connected alias must inherit canonical color and order without inventing a connection from launch")
        store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: JSONSerialization.data(withJSONObject: [
            "type": "state", "sessionID": "resumed-alias", "state": "working"])))
        let workingAuthority = (try row("resumed-alias")["sessionActions"] as! [String: Any])["resumeAuthority"] as! [String: Any]
        precondition(NSDictionary(dictionary: workingAuthority).isEqual(to: savedResumeAuthority),
                     "Connected aliases and ordinary new work cannot invent a retirement or discard its canonical scope")
        store.server.onDisconnect("resumed-alias")
        store.updateCatalog(catalog)
        precondition((try row("resumed-alias")["sessionActions"] as! [String: Any])["resumable"] as? Bool == true,
                     "After the matching owner actually connected and later ended, a fresh explicit saved-session launch must be possible")
        let claudeID = "33333333-3333-4333-8333-333333333333"
        store.updateClaudeCatalog([SavedClaude(id: claudeID, title: "Synthetic Claude", cwd: root.path, lastActivity: nil)])
        owner = 123
        let ownedResume = try sessionCommand(claudeID, "resume_session")
        try emit(store.internet, [ownedResume]); try sessionResult(ownedResume, status: "failed")
        precondition(launchedSessions.count == 1, "An undiscovered live owner still blocks phone launch without focusing")
        owner = nil
        let failureID = "44444444-4444-4444-8444-444444444444"
        store.updateClaudeCatalog([SavedClaude(id: failureID, title: "Synthetic failure", cwd: root.path, lastActivity: nil)])
        let failureResume = try sessionCommand(failureID, "resume_session")
        try emit(store.internet, [failureResume]); wait { launchContinuation != nil }
        precondition(launchedSessions.last?.agent == "claude" && launchedSessions.last?.id == failureID)
        launchContinuation?.resume(throwing: TerminalSessionError.timedOut); launchContinuation = nil
        try sessionResult(failureResume, status: "unknown")
        precondition((try row(failureID)["sessionActions"] as! [String: Any])["resumable"] as? Bool == false)
        let failedReset = try sessionCommand(failureID, "reset_session_color")
        try emit(store.internet, [failedReset]); try sessionResult(failedReset, status: "color_reset")
        let uncertainMetadata = try row(failureID)["sessionActions"] as! [String: Any]
        precondition(uncertainMetadata["resumable"] as? Bool == false &&
            (uncertainMetadata["resumeAuthority"] as? [String: Any])?["retired"] as? Int == 0,
                     "Color changes cannot authorize an unobserved uncertain launch")
        let lateID = "55555555-5555-4555-8555-555555555555"
        store.updateClaudeCatalog([SavedClaude(id: lateID, title: "Late synthetic launch", cwd: root.path, lastActivity: nil)])
        let lateResume = try sessionCommand(lateID, "resume_session")
        try emit(store.internet, [lateResume]); wait { launchContinuation != nil }
        try emit(store.internet, [remoteStatus("paused")])
        launchContinuation?.resume(); launchContinuation = nil
        wait { store.resumeResults["claude:" + lateID]?.status == "awaiting_connection" }
        try emit(store.internet, [remoteStatus("connected")])
        precondition(try !events(store.internet).contains { $0["id"] as? String == lateResume["id"] as? String },
                     "A late launch result must not enter a replacement phone channel")
        let warningID = "66666666-6666-4666-8666-666666666666"
        let warningSaved = SavedClaude(id: warningID, title: "Repeated synthetic launch", cwd: root.path, lastActivity: nil)
        store.updateClaudeCatalog([warningSaved])
        let firstLaunch = try sessionCommand(warningID, "resume_session")
        try emit(store.internet, [firstLaunch]); wait { launchContinuation != nil }
        let firstLaunchTime = Date()
        launchContinuation?.resume(); launchContinuation = nil
        try sessionResult(firstLaunch, status: "launched")
        store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: JSONSerialization.data(withJSONObject: [
            "type": "hello", "sessionID": warningID, "agent": "claude", "cwd": root.path])))
        RunLoop.current.run(until: firstLaunchTime.addingTimeInterval(0.3))
        store.server.onDisconnect(warningID)
        store.updateClaudeCatalog([warningSaved])
        let laterLaunch = try sessionCommand(warningID, "resume_session")
        try emit(store.internet, [laterLaunch]); wait { launchContinuation != nil }
        launchContinuation?.resume(); launchContinuation = nil
        try sessionResult(laterLaunch, status: "launched")
        RunLoop.current.run(until: firstLaunchTime.addingTimeInterval(0.7))
        precondition(store.resumeResults["claude:" + warningID]?.status == "awaiting_connection",
                     "A previous launch warning must not expire a later explicitly authorized launch")
        let unbridgedID = "77777777-7777-4777-8777-777777777777"
        let unbridgedSaved = SavedClaude(id: unbridgedID, title: "Owner without Notify", cwd: root.path, lastActivity: nil)
        store.updateClaudeCatalog([unbridgedSaved])
        let beforeUnbridged = try row(unbridgedID)["sessionActions"] as! [String: Any]
        let unbridgedLaunch = try sessionCommand(unbridgedID, "resume_session")
        try emit(store.internet, [unbridgedLaunch]); wait { launchContinuation != nil }
        launchContinuation?.resume(); launchContinuation = nil
        try sessionResult(unbridgedLaunch, status: "launched")
        store.updateClaudeCatalog([SavedClaude(id: unbridgedID, title: "Owner without Notify", cwd: root.path, lastActivity: nil, pid: 123)])
        let ownerOnly = try row(unbridgedID)
        precondition(ownerOnly["ticket"] as? String == unbridgedLaunch["ticket"] as? String &&
            (ownerOnly["sessionActions"] as! [String: Any])["resumeStatus"] as? String == "owner_detected",
            "Catalog owner observation must not pretend that the Notify bridge connected or replaced work")
        store.updateClaudeCatalog([unbridgedSaved])
        let savedAgain = try row(unbridgedID)
        let savedAgainActions = savedAgain["sessionActions"] as! [String: Any]
        precondition(savedAgain["ticket"] as? String == unbridgedLaunch["ticket"] as? String &&
            savedAgainActions["resumable"] as? Bool == true,
            "An original CLI owner can exit back to Saved without ever changing the runtime ticket")
        let firstRetirement = savedAgainActions["resumeAuthority"] as! [String: Any]
        precondition(firstRetirement["epoch"] as? String == (beforeUnbridged["resumeAuthority"] as! [String: Any])["epoch"] as? String &&
            firstRetirement["retired"] as? Int == 1,
            "Only observed retirement advances the native scoped resume authority")
        let changedColor = try sessionCommand(unbridgedID, "set_session_color", extra: ["rgb": 0x123456])
        try emit(store.internet, [changedColor]); try sessionResult(changedColor, status: "color_saved")
        let coloredAfterOwner = try row(unbridgedID)["sessionActions"] as! [String: Any]
        precondition(NSDictionary(dictionary: coloredAfterOwner["resumeAuthority"] as! [String: Any]).isEqual(to: firstRetirement),
                     "An unrelated metadata generation cannot change the retired launch authority")
        let launchCountBeforeReplay = launchedSessions.count
        try emit(store.internet, [unbridgedLaunch]); try sessionResult(unbridgedLaunch, status: "failed")
        precondition(launchedSessions.count == launchCountBeforeReplay, "Retirement never makes the original launch command replayable")
        let explicitResume = try sessionCommand(unbridgedID, "resume_session", connection: store.mobile)
        precondition(explicitResume["id"] as? String != unbridgedLaunch["id"] as? String)
        try emit(store.mobile, [explicitResume]); wait { launchContinuation != nil }
        launchContinuation?.resume(); launchContinuation = nil
        try sessionResult(explicitResume, status: "launched", connection: store.mobile)
        precondition(launchedSessions.count == launchCountBeforeReplay + 1)
        store.updateClaudeCatalog([SavedClaude(id: unbridgedID, title: "Owner without Notify", cwd: root.path, lastActivity: nil, pid: 456)])
        store.updateClaudeCatalog([unbridgedSaved])
        let afterTwoPhones = try row(unbridgedID)["sessionActions"] as! [String: Any]
        let initialAuthority = beforeUnbridged["resumeAuthority"] as? [String: Any]
        let retiredAuthority = afterTwoPhones["resumeAuthority"] as? [String: Any]
        let olderReviewRetired = initialAuthority?["epoch"] as? String != nil &&
            initialAuthority?["epoch"] as? String == retiredAuthority?["epoch"] as? String &&
            (retiredAuthority?["retired"] as? Int ?? -1) > (initialAuthority?["retired"] as? Int ?? -1)
        precondition(olderReviewRetired && retiredAuthority?["retired"] as? Int == 2,
                     "Phone A must retain native retirement authorization after phone B retires, even when A misses every intermediate snapshot")
        store.updateClaudeCatalog([unbridgedSaved])
        let repeatedAuthority = (try row(unbridgedID)["sessionActions"] as! [String: Any])["resumeAuthority"] as! [String: Any]
        precondition(NSDictionary(dictionary: repeatedAuthority).isEqual(to: retiredAuthority!),
                     "Repeated Saved discovery must not invent another retirement")
        store.updateClaudeCatalog([SavedClaude(id: unbridgedID, title: "Replacement work", cwd: root.appendingPathComponent("other-project").path, lastActivity: nil)])
        let replacementAuthority = (try row(unbridgedID)["sessionActions"] as! [String: Any])["resumeAuthority"] as! [String: Any]
        precondition(replacementAuthority["epoch"] as? String != retiredAuthority?["epoch"] as? String &&
            replacementAuthority["retired"] as? Int == 0, "Changed native work binding must get a fresh epoch, not credit for previous retirements")
        precondition(store.removeDisconnected(unbridgedID))
        store.updateClaudeCatalog([unbridgedSaved])
        let recreatedAuthority = (try row(unbridgedID)["sessionActions"] as! [String: Any])["resumeAuthority"] as! [String: Any]
        precondition(recreatedAuthority["epoch"] as? String != replacementAuthority["epoch"] as? String &&
            recreatedAuthority["retired"] as? Int == 0, "Removing/recreating a cached identity must not resurrect its retirement scope")
        let replacementStore = Store(directory: root.appendingPathComponent("replacement-store"), defaults: MemoryDefaults(),
            mobileResources: resources, terminal: terminal)
        replacementStore.updateClaudeCatalog([unbridgedSaved])
        let replacementOverview = try JSONSerialization.jsonObject(with: replacementStore.phoneWorkspaceSnapshot(watching: [])[0]) as! [String: Any]
        let replacementRow = (replacementOverview["sessions"] as! [[String: Any]]).first!
        let restartedAuthority = (replacementRow["sessionActions"] as! [String: Any])["resumeAuthority"] as! [String: Any]
        precondition(restartedAuthority["epoch"] as? String != recreatedAuthority["epoch"] as? String &&
            restartedAuthority["retired"] as? Int == 0, "A new Store instance cannot authorize old uncertain attempts")
        replacementStore.stop()
        let scopeRaceID = "88888888-8888-4888-8888-888888888888"
        let scopeRaceSaved = SavedClaude(id: scopeRaceID, title: "Scope race", cwd: root.path, lastActivity: nil)
        store.updateClaudeCatalog([scopeRaceSaved])
        pauseOwner = true
        let scopeRace = try sessionCommand(scopeRaceID, "resume_session")
        try emit(store.internet, [scopeRace]); wait { ownerContinuation != nil }
        let beforeScopeRace = launchedSessions.count
        store.updateClaudeCatalog([SavedClaude(id: scopeRaceID, title: "Replacement", cwd: root.appendingPathComponent("other-project").path, lastActivity: nil)])
        store.updateClaudeCatalog([scopeRaceSaved])
        pauseOwner = false
        ownerContinuation?.resume(returning: nil); ownerContinuation = nil
        try wait { try launchContinuation != nil || events(store.internet).contains {
            $0["id"] as? String == scopeRace["id"] as? String && $0["status"] as? String == "failed"
        } }
        launchContinuation?.resume(throwing: TerminalSessionError.timedOut); launchContinuation = nil
        precondition(launchedSessions.count == beforeScopeRace,
                     "A changed-and-restored work scope during owner lookup must not launch under an old phone review")
        try sessionResult(scopeRace, status: "failed")
        // Keep existing fixtures' one-session assumptions intact.
        store.server.onDisconnect("resumed-alias")
        _ = store.removeDisconnected("resumed-alias")
        store.server.onDisconnect(peerID)
        _ = store.removeDisconnected(peerID)
        store.updateCatalog([])
        store.updateClaudeCatalog([])
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
        try packet(["type": "capabilities", "steering": true, "subagentCreate": true, "subagentRemove": true,
                    "subagentStop": true, "idleSubagentCleanup": true, "subagentTypes": ["reviewer"], "subagentModels": ["live-model"]])
        try packet(["type": "team", "team": ["agents": [
            ["id": "ended", "name": "Ended helper", "task": "", "status": "completed", "parentKnown": true],
            ["id": "idle", "name": "Idle helper", "task": "", "status": "idle", "parentKnown": true]
        ], "runningCount": 0, "idleCount": 1, "truncated": false]])
        func managementCommand(_ action: String, model: String? = "live-model") throws -> [String: Any] {
            let overview = try JSONSerialization.jsonObject(with: store.phoneWorkspaceSnapshot(watching: ["fixture"], from: store.internet).first!) as! [String: Any]
            let row = (overview["sessions"] as! [[String: Any]])[0]
            var value: [String: Any] = ["type": "control", "id": UUID().uuidString, "sessionID": "fixture",
                "ticket": row["ticket"]!, "managementTicket": row["managementTicket"]!, "action": action, "text": ""]
            if action == "create_subagent" {
                var creation = ["name": "Phone reviewer", "agentType": "reviewer", "prompt": "  Exact creation instructions\n"]
                if let model { creation["model"] = model }
                value["creation"] = creation
            }
            if action == "remove_subagent" { value["agentID"] = "ended" }
            return value
        }
        func runtimePackets() throws -> [[String: Any]] {
            let text = try String(contentsOf: store.directory.appendingPathComponent("mobile/agent.jsonl"), encoding: .utf8)
            return try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        }
        store.steeringWorkspace.setDraft("Native main draft", sessionID: "fixture")
        store.steeringWorkspace.setDraft("Native helper draft", sessionID: "fixture", agentID: "idle")
        for (action, ack) in [("create_subagent", "created"), ("remove_subagent", "removed"), ("stop_idle_subagents", "cleaned")] {
            var input = try managementCommand(action)
            // The helper stdin -> MobileConnection -> Store -> actual runtime socket route.
            try emit(store.internet, [input])
            let commandID = store.steeringWorkspace.history["fixture"]!.last!.id
            try wait { try runtimePackets().contains { $0["commandID"] as? String == commandID } }
            let sent = try runtimePackets().first { $0["commandID"] as? String == commandID }!
            precondition(sent["action"] as? String == action, "Expected \(action); got \(sent); native: \(store.error ?? "none")")
            precondition((sent["agentID"] as? String) == (action == "remove_subagent" ? "ended" : nil))
            if action == "create_subagent" {
                precondition(sent["text"] as? String == "  Exact creation instructions\n" &&
                    sent["agentName"] as? String == "Phone reviewer" && sent["agentType"] as? String == "reviewer" &&
                    sent["model"] as? String == "live-model")
            } else { precondition(sent["text"] as? String == "") }
            try packet(["type": "control_status", "commandID": commandID, "status": "received"])
            precondition(store.steeringWorkspace.history["fixture"]!.last!.status == "sending", "Chat ACK cannot complete management")
            let id = input["id"] as! String
            precondition(try !events(store.internet).contains { $0["id"] as? String == id })
            try packet(["type": "control_status", "commandID": commandID, "status": ack,
                "text": "Cancelled 2; skipped 1; failed 0; uncertain 0"])
            try wait { try events(store.internet).contains { $0["id"] as? String == id && $0["ok"] as? Bool == true && $0["status"] as? String == ack } }
            if action == "create_subagent" {
                var changed = input["creation"] as! [String: String]
                changed["prompt"] = "Do not echo"
                input["creation"] = changed
            }
            try emit(store.internet, [input])
            precondition(store.steeringWorkspace.history["fixture"]!.last!.id == commandID)
        }
        precondition(store.steeringWorkspace.draft(sessionID: "fixture") == "Native main draft" &&
            store.steeringWorkspace.draft(sessionID: "fixture", agentID: "idle") == "Native helper draft")
        for (action, status) in [("stop_idle_subagents", "failed"), ("stop_idle_subagents", "unknown"),
                                 ("create_subagent", "failed"), ("create_subagent", "created"), ("remove_subagent", "removed")] {
            try packet(["type": "capabilities", "steering": true, "subagentCreate": true, "subagentRemove": true,
                        "subagentStop": true, "idleSubagentCleanup": true, "subagentTypes": ["reviewer"], "subagentModels": ["live-model"]])
            try packet(["type": "team", "team": ["agents": [
                ["id": "ended", "name": "Ended helper", "task": "", "status": "completed", "parentKnown": true]
            ], "runningCount": 0, "idleCount": 0, "truncated": false]])
            let input = try managementCommand(action)
            let inputID = input["id"] as! String
            try emit(store.internet, [input])
            let commandID = store.steeringWorkspace.history["fixture"]!.last!.id
            try wait { try runtimePackets().contains { $0["commandID"] as? String == commandID } }
            // Cleanup may publish unavailable before returning partial counts; catalogs/removals have the same ordering.
            let metadataChange = try sessionCommand("fixture", "reset_session_color")
            try emit(store.internet, [metadataChange]); try sessionResult(metadataChange, status: "color_reset")
            try packet(["type": "capabilities", "steering": true, "subagentCreate": true, "subagentRemove": false,
                        "subagentStop": true, "idleSubagentCleanup": false, "subagentTypes": ["reviewer"], "subagentModels": []])
            try packet(["type": "team", "team": ["agents": [], "runningCount": 0, "idleCount": 0, "truncated": false]])
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            precondition(try !events(store.internet).contains { $0["id"] as? String == inputID },
                         "Admission change must not settle the dispatched \(action) before its actual runtime result")
            let reviewed = try JSONDecoder().decode(MobileControl.self, from: JSONSerialization.data(withJSONObject: input))
            precondition(!store.internet.workspace.accepts(reviewed, session: store.registry.sessions["fixture"]!),
                         "The previous management ticket must still reject newly reviewed work")
            let counts = action == "stop_idle_subagents"
                ? "Cancelled 2; skipped 3; failed 0; uncertain \(status == "unknown" ? 1 : 0). Later runtime observation failed. Main agent was not targeted."
                : action == "create_subagent"
                    ? (status == "created" ? "Created subagent “Phone reviewer”. Requested model: live-model."
                        : "This model is no longer available in the live session catalog.")
                    : "Ended subagent removed from the list. No files were deleted."
            try packet(["type": "control_status", "commandID": commandID, "status": status, "text": counts])
            let ok = ["created", "removed"].contains(status)
            try wait { try events(store.internet).contains {
                $0["id"] as? String == inputID && $0["status"] as? String == status &&
                $0["ok"] as? Bool == ok && $0["detail"] as? String == counts
            } }
        }
        try packet(["type": "capabilities", "steering": true, "subagentCreate": true, "subagentRemove": true,
                    "subagentStop": true, "idleSubagentCleanup": true, "subagentTypes": ["reviewer"], "subagentModels": ["live-model"]])
        let supersededCleanup = try managementCommand("stop_idle_subagents")
        let supersededID = supersededCleanup["id"] as! String
        try emit(store.internet, [supersededCleanup])
        let supersededReceipt = store.steeringWorkspace.history["fixture"]!.last!.id
        try wait { try runtimePackets().contains { $0["commandID"] as? String == supersededReceipt } }
        try packet(["type": "activity", "activity": ["id": "superseding-main-work", "kind": "user",
            "title": "Synthetic new work", "detail": "A different main turn", "status": "complete",
            "timestamp": "2026-11-18T00:00:00Z"]])
        try wait { try events(store.internet).contains { $0["id"] as? String == supersededID && $0["status"] as? String == "unknown" } }
        try packet(["type": "control_status", "commandID": supersededReceipt, "status": "failed", "text": "Late obsolete counts"])
        precondition(try !events(store.internet).contains { $0["id"] as? String == supersededID && $0["detail"] as? String == "Late obsolete counts" },
                     "A replaced work generation must not accept late management results")
        let auditPath = store.directory.appendingPathComponent("history.json")
        try FileManager.default.removeItem(at: auditPath)
        try FileManager.default.createDirectory(at: auditPath, withIntermediateDirectories: false)
        let blockedCreation = try managementCommand("create_subagent")
        let beforeBlocked = try runtimePackets().count
        try emit(store.internet, [blockedCreation])
        try wait { try events(store.internet).contains { $0["id"] as? String == blockedCreation["id"] as? String && $0["ok"] as? Bool == false } }
        precondition(try runtimePackets().count == beforeBlocked, "Audit failure must not dispatch creation")
        try FileManager.default.removeItem(at: auditPath)
        let timedOutCreation = try managementCommand("create_subagent", model: nil)
        try emit(store.internet, [timedOutCreation])
        let timedOutReceipt = store.steeringWorkspace.history["fixture"]!.last!.id
        precondition(store.steeringWorkspace.history["fixture"]!.last!.action == "create_subagent")
        RunLoop.current.run(until: Date().addingTimeInterval(10.2))
        try wait { try events(store.internet).contains {
            $0["id"] as? String == timedOutCreation["id"] as? String && $0["status"] as? String == "unknown" && $0["ok"] as? Bool == false
        } }
        let beforeReplay = try runtimePackets().count
        try emit(store.internet, [timedOutCreation])
        precondition(try runtimePackets().count == beforeReplay, "Timed-out creation must not be dispatched twice")
        try packet(["type": "control_status", "commandID": timedOutReceipt, "status": "created", "text": "Late runtime creation"])
        precondition(try !events(store.internet).contains {
            $0["id"] as? String == timedOutCreation["id"] as? String && $0["ok"] as? Bool == true
        }, "Late ACK must not rewrite the settled unknown phone outcome")
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
