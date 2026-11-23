import AppKit
import SwiftUI
import NotifyCore
import Vision
import Network

private final class AttentionDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func register(defaults registration: [String: Any]) { values.merge(registration) { existing, _ in existing } }
}

enum AttentionChecks {
    @MainActor static func run() throws {
        let root = URL(fileURLWithPath: ".build/attention-fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = AttentionDefaults()
        defaults.set(false, forKey: "autoYes")
        defaults.set(true, forKey: "hasSeenWelcome")
        let store = Store(directory: root, defaults: defaults, mobileResources: root)
        defer { store.stop() }
        var failures: [String] = []
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        func receive(_ value: [String: Any]) throws {
            store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: JSONSerialization.data(withJSONObject: value)))
        }
        func hello(_ session: String) throws {
            try receive(["type": "hello", "sessionID": session, "agent": "copilot", "cwd": "/Projects/example"])
        }
        func request(_ id: String, session: String) throws {
            try receive(["type": "request", "sessionID": session, "request": [
                "id": id, "kind": "permission", "title": "Review \(id)", "detail": "Synthetic request",
                "autoEligible": false, "questions": []
            ]])
        }
        func current(_ session: String, _ request: String) -> Bool {
            store.attentionRequest?.sessionID == session && store.attentionRequest?.requestID == request
        }
        expect(store.attentionRequest == nil && store.additionalAttentionCount == 0, "Empty state has no indicator or extra count")
        let emptyProjection = store.phoneAttentionSnapshot()
        expect(emptyProjection != nil && emptyProjection?.current == nil && emptyProjection?.additionalCount == 0,
               "Canonical empty is explicit display metadata, not missing support")
        try hello("orchard")
        try receive(["type": "error", "sessionID": "orchard", "text": "An old session error"])
        expect(store.attentionRequest == nil, "Generic session errors do not create attention requests")
        try request("first", session: "orchard")
        expect(current("orchard", "first") && store.additionalAttentionCount == 0, "One current request has zero additional requests")
        try hello("garden")
        try request("second", session: "garden")
        try request("third", session: "garden")
        expect(current("orchard", "first") && store.additionalAttentionCount == 2, "New arrivals keep the current request and show +2, not +3")
        let projected = store.phoneAttentionSnapshot()
        expect(projected?.current?.requestID == "first" && projected?.additionalCount == 2,
               "Phone projection mirrors canonical identity and exact additional count")
        expect(projected?.epoch == emptyProjection?.epoch && (projected?.revision ?? 0) > (emptyProjection?.revision ?? 0),
               "Projection changes advance revision in one Store epoch")
        expect(store.phoneAttentionSnapshot() == projected, "Duplicate snapshots retain the same revision")
        if let projected {
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(projected)) as! [String: Any]
            expect(Set(encoded.keys) == Set(["version", "epoch", "revision", "current", "additionalCount"]),
                   "Projection only carries bounded display metadata")
            expect(store.internet.canonicalAttentionSnapshot?() == projected && store.mobile.canonicalAttentionSnapshot?() == projected,
                   "Both connection bindings project the same Store epoch and selection")
            if let destination = ProcessInfo.processInfo.environment["NOTIFY_ATTENTION_FIXTURE"] {
                let items = store.phoneSnapshot(from: store.internet)
                struct Fixture: Encodable {
                    let type = "snapshot"
                    let requests: [MobileItem]
                    let total: Int
                    let attention: MobileAttention
                }
                try JSONEncoder().encode(Fixture(requests: items, total: items.count, attention: projected))
                    .write(to: URL(fileURLWithPath: destination))
            }
        }
        if let emptyProjection {
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(emptyProjection)) as! [String: Any]
            expect(encoded["current"] is NSNull, "Canonical empty encodes explicit JSON null rather than an omitted current")
        }
        store.automaticallySending.insert("second")
        expect(current("orchard", "first") && store.additionalAttentionCount == 1, "Automatic requests do not inflate the additional count")
        expect(store.phoneAttentionSnapshot()?.additionalCount == 1, "Projection excludes automatically handled other requests")
        store.automaticallySending.remove("second")
        store.select("garden", request: "third")
        expect(current("garden", "third"), "Explicit selection pins the exact cross-session request")
        expect(store.phoneAttentionSnapshot()?.current?.requestID == "third", "Explicit Mac selection projects the same chosen request")
        let floatingBefore = store.replyWorkspace.floatingID
        store.select("orchard", request: "first")
        store.select("garden", request: "third")
        try hello("meadow")
        store.select("meadow")
        store.openAttentionRequest()
        expect(store.selectedID == "garden" && store.activeRequest?.id == "third", "Indicator opens the exact original request")
        let focus = store.decisionFocus
        store.openAttentionRequest()
        expect(store.decisionFocus != focus, "Repeated clicks still reopen the Decision surface")
        expect(store.replyWorkspace.floatingID == floatingBefore, "Indicator navigation does not change floating reply focus")
        try request("new-arrival", session: "orchard")
        expect(current("garden", "third") && store.activeRequest?.id == "third", "New arrivals do not steal an explicitly selected pending item")
        store.snooze("third")
        expect(current("garden", "third"), "Snoozing the floating card does not hide global pending work")
        store.sending.insert("third")
        expect(current("garden", "third") && store.additionalAttentionCount == 3, "Sending stays pending until acknowledgment")
        expect(store.phoneAttentionSnapshot()?.current?.requestID == "third", "Dispatch is not projected as resolution")
        store.sending.remove("third")
        store.reply(session: "garden", request: store.registry.sessions["garden"]!.requests.first { $0.id == "third" }!, decision: "allow")
        expect(store.requestErrors["third"] != nil && current("garden", "third"), "Failed transport send retains the current request")
        try receive(["type": "error", "sessionID": "garden", "requestID": "third", "text": "Delivery uncertain; check before retrying."])
        expect(current("garden", "third"), "Uncertain delivery remains pending, not completed")
        try receive(["type": "resolved", "sessionID": "orchard", "requestID": "third", "cancelled": true])
        expect(current("garden", "third"), "Resolution for another session cannot remove the current request")
        try receive(["type": "resolved", "sessionID": "garden", "requestID": "third", "decision": "allow"])
        expect(store.attentionRequest != nil && !current("garden", "third") && store.additionalAttentionCount == 2,
               "Only acknowledgment advances away from the resolved current request")
        expect(store.sending.isEmpty && store.pending.count == 3, "Advancing never answers another request")
        expect(store.phoneAttentionSnapshot()?.current?.requestID != "third", "Canonical runtime acknowledgment advances the projected selection")
        store.select("orchard", request: "first")
        try receive(["type": "resolved", "sessionID": "orchard", "requestID": "first", "cancelled": true])
        expect(store.attentionRequest != nil && !current("orchard", "first") && store.additionalAttentionCount == 1,
               "Withdrawal advances to remaining pending work")
        store.select("garden", request: "second")
        store.server.onDisconnect("garden")
        expect(current("garden", "second") && !store.attentionIsActionable && store.additionalAttentionCount == 1,
               "Disconnect retains the unresolved current request as unknown, with other manual requests still counted")
        expect(store.phoneAttentionSnapshot()?.current?.requestID == "second", "Disconnect does not erase the display-only projection")
        let disconnectedFocus = store.decisionFocus
        store.openAttentionRequest()
        expect(store.decisionFocus == disconnectedFocus, "Disconnected current request cannot navigate to actionable Decision")
        store.automaticallySending.insert("new-arrival")
        expect(current("garden", "second") && store.additionalAttentionCount == 0, "Automatic work does not replace a disconnected current request")
        store.automaticallySending.remove("new-arrival")
        expect(current("garden", "second") && store.additionalAttentionCount == 1, "Other uncertain work does not replace unresolved current work")
        store.server.onDisconnect("orchard")
        expect(current("garden", "second") && store.additionalAttentionCount == 0, "All disconnected retains current unknown request, not an actionable badge")
        try receive(["type": "resolved", "sessionID": "garden", "requestID": "second", "cancelled": true])
        expect(store.attentionRequest == nil, "Authoritative withdrawal removes current unknown work without promoting unrelated stale work")
        try hello("automatic-offline")
        store.automaticallySending.insert("background-only")
        try request("background-only", session: "automatic-offline")
        expect(store.attentionRequest == nil, "A noncurrent automatic-only request is not promoted")
        expect(store.phoneAttentionSnapshot()?.current == nil, "Automatic-only new work is not projected as manual attention")
        store.server.onDisconnect("automatic-offline")
        expect(store.attentionRequest == nil, "Disconnect cleanup must not newly promote noncurrent automatic-only work")
        try observationRefreshChecks(expect: expect)
        try transportChecks(expect: expect)
        try receive(["type": "hello", "sessionID": "bounded", "agent": "copilot",
                     "cwd": "/Projects/" + String(repeating: "🌳", count: 200)])
        try receive(["type": "request", "sessionID": "bounded", "request": [
            "id": "bounded-title", "kind": "permission", "title": String(repeating: "🌳", count: 200),
            "detail": "", "autoEligible": false, "questions": []
        ]])
        store.select("bounded", request: "bounded-title")
        let bounded = store.phoneAttentionSnapshot()?.current
        expect(bounded != nil && bounded!.sessionName.utf16.count <= 256 && bounded!.requestTitle.utf16.count <= 300,
               "Projection bounds display labels in the same UTF-16 units as phone/helper validation")
        expect(bounded?.requestTitle.hasSuffix("…") == true && bounded?.requestTitle.contains("\u{FFFD}") == false,
               "Truncating display titles does not split a Unicode scalar or alter identity")
        let replacement = Store(directory: root, defaults: defaults, mobileResources: root)
        expect(replacement.phoneAttentionSnapshot()?.epoch != store.phoneAttentionSnapshot()?.epoch,
               "A replacement Store cannot claim the old source epoch")
        replacement.stop()
        if !failures.isEmpty {
            FileHandle.standardError.write(Data(failures.map { "FAIL: \($0)\n" }.joined().utf8))
            throw NSError(domain: "AttentionChecks", code: failures.count, userInfo: [NSLocalizedDescriptionKey: "\(failures.count)/\(checks) attention checks failed"])
        }
        print("Global attention: \(checks) headless checks passed")
    }

    @MainActor private static func observationRefreshChecks(expect: (Bool, String) -> Void) throws {
        let root = URL(fileURLWithPath: ".build/attention-refresh-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = AttentionDefaults()
        defaults.set(false, forKey: "autoYes")
        defaults.set(true, forKey: "hasSeenWelcome")
        let store = Store(directory: root, defaults: defaults, mobileResources: root)
        defer { store.stop() }
        func receive(_ value: [String: Any]) throws {
            store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: JSONSerialization.data(withJSONObject: value)))
        }
        func hello(_ session: String, agent: String = "copilot") throws {
            try receive(["type": "hello", "sessionID": session, "agent": agent, "cwd": "/Projects/orchard"])
        }
        func request(_ id: String, session: String) throws {
            try receive(["type": "request", "sessionID": session, "request": [
                "id": id, "kind": "permission", "title": "Review \(id)", "detail": "Synthetic refresh request",
                "autoEligible": false, "questions": []
            ]])
        }
        func current(_ session: String, _ id: String) -> Bool {
            store.attentionRequest?.sessionID == session && store.attentionRequest?.requestID == id
        }
        func cannotOpen(_ message: String) {
            let focus = store.decisionFocus
            let selected = store.selectedID
            store.openAttentionRequest()
            expect(store.decisionFocus == focus && store.selectedID == selected, message)
        }
        try hello("orchard")
        try request("original", session: "orchard")
        try hello("garden")
        try request("other", session: "garden")
        store.select("orchard", request: "original")
        store.server.onDisconnect("orchard")
        try hello("orchard")
        expect(current("orchard", "original") && store.additionalAttentionCount == 1,
               "Reconnect hello with an empty registry must not advance before pending replay")
        expect(store.phoneAttentionSnapshot()?.current?.requestID == "original",
               "The phone projection preserves the canonical incumbent through empty hello replay")
        cannotOpen("A reconnect hello alone cannot re-enable the old request")
        try receive(["type": "state", "sessionID": "orchard", "state": "ready"])
        try receive(["type": "capabilities", "sessionID": "orchard", "sessionAutoYes": true])
        try request("unrelated-replay", session: "orchard")
        expect(current("orchard", "original") && store.additionalAttentionCount == 2,
               "State/capabilities and unrelated replay are not a complete pending snapshot or withdrawal")
        cannotOpen("Other replayed requests do not authorize the unreplayed current request")
        try request("original", session: "orchard")
        expect(current("orchard", "original"), "Exact pending replay restores the original current request, not the fallback")
        let focus = store.decisionFocus
        store.openAttentionRequest()
        expect(store.decisionFocus != focus && store.selectedID == "orchard" && store.activeRequest?.id == "original",
               "Fresh exact replay restores canonical navigation authority")
        store.server.onDisconnect("orchard")
        try hello("orchard")
        store.select("garden", request: "other")
        try request("original", session: "orchard")
        expect(current("garden", "other"), "Explicit selection may replace unknown current; later replay cannot steal it")
        store.select("orchard", request: "original")
        store.server.onDisconnect("orchard")
        try hello("orchard")
        expect(current("orchard", "original"), "No replay of the current request remains unknown, even if it may have been answered offline")
        cannotOpen("Absence without a complete snapshot cannot become action authority")
        try receive(["type": "resolved", "sessionID": "orchard", "requestID": "original", "cancelled": true])
        expect(current("garden", "other"), "Authoritative withdrawal advances a retained current item even when absent from the registry")

        let observed = "11111111-1111-4111-8111-111111111111"
        try hello(observed, agent: "claude")
        try request("catalog-current", session: observed)
        store.select(observed, request: "catalog-current")
        store.server.onDisconnect(observed)
        store.updateClaudeCatalog([SavedClaude(id: observed, title: "Orchard notes", cwd: "/Projects/orchard", lastActivity: nil, pid: 4321)])
        expect(store.registry.sessions[observed]?.requests.isEmpty == true && current(observed, "catalog-current"),
               "Running-owner catalog refresh may clear registry requests but must retain the current unknown item")
        cannotOpen("Catalog presence and a running owner do not confirm a pending request")
        store.updateClaudeCatalog([SavedClaude(id: observed, title: "Orchard notes", cwd: "/Projects/orchard", lastActivity: nil)])
        store.updateClaudeCatalog([])
        expect(store.registry.sessions[observed] == nil && current(observed, "catalog-current"),
               "Catalog omission removes an observation record, not the retained unresolved current request")
        cannotOpen("A removed observation record has no action authority")
        try receive(["type": "resolved", "sessionID": observed, "requestID": "catalog-current", "decision": "allow"])
        expect(current("garden", "other"), "Explicit ACK of an absent current record, not disappearance, permits advancement")

        try hello("removed")
        try request("removed-current", session: "removed")
        store.select("removed", request: "removed-current")
        store.server.onDisconnect("removed")
        expect(store.removeDisconnected("removed") && current("removed", "removed-current"),
               "Removing a disconnected sidebar record does not confirm the pending request was answered")
        cannotOpen("Removed sidebar records cannot supply approval/navigation authority")
        try receive(["type": "resolved", "sessionID": "removed", "requestID": "removed-current", "cancelled": true])
        expect(current("garden", "other"), "Withdrawal of removed current work can advance")

        let alias = "22222222-2222-4222-8222-222222222222"
        try hello(alias)
        try request("alias-current", session: alias)
        store.select(alias, request: "alias-current")
        store.server.onDisconnect(alias)
        try hello("replacement")
        try receive(["type": "metadata", "sessionID": "replacement", "sourceSessionID": alias, "title": "Orchard notes"])
        try request("alias-current", session: "replacement")
        expect(store.registry.sessions[alias] == nil && current(alias, "alias-current"),
               "Alias cleanup and a different runtime session do not silently resolve or rebind the original exact request")
        cannotOpen("A request ID on a different runtime session cannot reactivate retained work")
        store.select("replacement", request: "alias-current")
        expect(current("replacement", "alias-current"), "Explicit selection may move to freshly confirmed replacement-session work")
    }

    @MainActor private static func transportChecks(expect: (Bool, String) -> Void) throws {
        let root = URL(fileURLWithPath: ".build/attention-socket-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = AttentionDefaults()
        defaults.set(false, forKey: "autoYes")
        defaults.set(true, forKey: "hasSeenWelcome")
        let store = Store(directory: root, defaults: defaults, mobileResources: root)
        defer { store.stop() }
        func wait(_ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(4)
            while !condition() && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            if !condition() { throw NSError(domain: "AttentionSocketTimeout", code: 1) }
        }
        var ready = false
        store.server.onReady = { ready = true }
        try store.server.start()
        try wait { ready }
        let endpoint = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("connection.json"))) as! [String: Any]
        let peer = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(endpoint["port"] as! Int))!, using: .tcp)
        defer { peer.cancel() }
        var packets: [[String: Any]] = []
        var buffer = Data()
        var receiveError: Error?
        func readNext() {
            peer.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                MainActor.assumeIsolated {
                    do {
                        if let data {
                            buffer.append(data)
                            while let newline = buffer.firstIndex(of: 10) {
                                let line = Data(buffer[..<newline])
                                buffer.removeSubrange(...newline)
                                packets.append(try JSONSerialization.jsonObject(with: line) as! [String: Any])
                            }
                        }
                    } catch { receiveError = error }
                    if let error { receiveError = error }
                    if !complete && error == nil { readNext() }
                }
            }
        }
        peer.start(queue: .main)
        readNext()
        func send(_ value: [String: Any], via connection: NWConnection? = nil) throws {
            var value = value
            value["sessionID"] = "socket-orchard"
            var data = try JSONSerialization.data(withJSONObject: value)
            data.append(10)
            (connection ?? peer).send(content: data, completion: .contentProcessed { error in
                MainActor.assumeIsolated {
                    if let error { receiveError = error }
                }
            })
        }
        func request(_ id: String, eligible: Bool) throws {
            try send(["type": "request", "request": [
                "id": id, "kind": "permission", "title": "Review \(id)", "detail": "Synthetic socket request",
                "autoEligible": false, "sessionAutoEligible": eligible, "questions": []
            ]])
            try wait { store.registry.sessions["socket-orchard"]?.requests.contains { $0.id == id } == true }
        }
        func replied(_ id: String) -> Bool { packets.contains { $0["type"] as? String == "reply" && $0["requestID"] as? String == id } }
        func ack(_ id: String, automatic: Bool = false) throws {
            try send(["type": "resolved", "requestID": id, "decision": "allow", "automatic": automatic])
            try wait { store.registry.sessions["socket-orchard"]?.requests.contains { $0.id == id } == false }
        }
        try send(["type": "hello", "token": endpoint["token"]!, "agent": "copilot", "cwd": "/Projects/orchard"])
        try wait { packets.contains { $0["type"] as? String == "welcome" } }
        try send(["type": "capabilities", "sessionAutoYes": true])
        try wait { store.registry.sessions["socket-orchard"]?.canAutoYes == true }
        try request("manual", eligible: false)
        try request("next", eligible: false)
        store.select("socket-orchard", request: "manual")
        store.reply(session: "socket-orchard", request: store.activeRequest!, decision: "allow")
        try wait { replied("manual") }
        expect(store.attentionRequest?.requestID == "manual" && store.sending.contains("manual") && store.requestErrors["manual"] == nil,
               "Successful socket send remains current and pending before runtime acknowledgment")
        try ack("manual")
        expect(store.attentionRequest?.requestID == "next" && !replied("next"), "Runtime socket ACK advances without answering next")
        try request("automatic-current", eligible: true)
        store.select("socket-orchard", request: "automatic-current")
        expect(store.setSessionDangerousAutoYes("socket-orchard", enabled: true) == nil, "Synthetic native policy can dispatch the selected eligible request")
        try wait { replied("automatic-current") }
        expect(store.attentionRequest?.requestID == "automatic-current" && store.automaticallySending.contains("automatic-current") && store.additionalAttentionCount == 1,
               "Enabling Dangerous Auto-yes keeps the already-current unresolved request until ACK")
        try request("automatic-other", eligible: true)
        try wait { replied("automatic-other") }
        expect(store.attentionRequest?.requestID == "automatic-current" && store.additionalAttentionCount == 1,
               "Other automatic dispatches neither replace the current request nor inflate its extra count")
        try send(["type": "error", "requestID": "automatic-current", "text": "Delivery uncertain; check before retrying."])
        try wait { store.requestErrors["automatic-current"] != nil }
        expect(store.attentionRequest?.requestID == "automatic-current", "Uncertain automatic delivery keeps the same unresolved request")
        try ack("automatic-current", automatic: true)
        expect(store.attentionRequest?.requestID == "next" && !replied("next"), "Automatic acknowledgment advances without granting unrelated manual work")
        try ack("automatic-other", automatic: true)
        try send(["type": "resolved", "requestID": "next", "cancelled": true])
        try wait { store.registry.sessions["socket-orchard"]?.requests.isEmpty == true }
        expect(store.setSessionDangerousAutoYes("socket-orchard", enabled: true) == nil, "Synthetic automatic-only fixture enables native policy")
        try request("automatic-only", eligible: true)
        try wait { replied("automatic-only") }
        expect(store.attentionRequest == nil, "A newly arriving automatic-only request is not newly surfaced as user attention")
        try ack("automatic-only", automatic: true)
        store.setSessionDangerousAutoYes("socket-orchard", enabled: false)
        try request("disconnect-current", eligible: false)
        store.select("socket-orchard", request: "disconnect-current")
        store.reply(session: "socket-orchard", request: store.activeRequest!, decision: "allow")
        try wait { replied("disconnect-current") }
        expect(receiveError == nil, "Synthetic transport completed without unexpected framing or connection errors")
        peer.cancel()
        try wait { store.registry.sessions["socket-orchard"]?.connected == false }
        expect(store.attentionRequest?.requestID == "disconnect-current" && !store.attentionIsActionable,
               "Socket loss after sending preserves the current unresolved request with unknown delivery")
        let focus = store.decisionFocus
        store.openAttentionRequest()
        expect(store.decisionFocus == focus, "Socket-disconnected current request is non-actionable")
        let reconnected = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(endpoint["port"] as! Int))!, using: .tcp)
        defer { reconnected.cancel() }
        reconnected.start(queue: .main)
        try send(["type": "hello", "token": endpoint["token"]!, "agent": "copilot", "cwd": "/Projects/orchard"], via: reconnected)
        try wait { store.registry.sessions["socket-orchard"]?.connected == true }
        expect(store.attentionRequest?.requestID == "disconnect-current" && !store.attentionIsActionable,
               "Authenticated reconnect retains unknown current without treating hello as pending confirmation")
        store.openAttentionRequest()
        expect(store.decisionFocus == focus, "Authenticated hello alone cannot open a cached request")
        try send(["type": "request", "request": [
            "id": "disconnect-current", "kind": "permission", "title": "Review reconnected current",
            "detail": "Synthetic replay", "autoEligible": false, "questions": []
        ]], via: reconnected)
        try wait { store.registry.sessions["socket-orchard"]?.requests.contains { $0.id == "disconnect-current" } == true }
        expect(store.attentionRequest?.requestID == "disconnect-current" && store.attentionRequest?.requestTitle == "Review reconnected current" && store.attentionIsActionable,
               "Fresh authenticated exact replay restores current display and canonical availability")
        store.openAttentionRequest()
        expect(store.decisionFocus != focus && store.activeRequest?.id == "disconnect-current",
               "Only the fresh request from the authenticated replacement connection can reopen Decision")
    }

    @MainActor static func captureOffscreen() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: ".build/attention-captures", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = output.appendingPathComponent("fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = AttentionDefaults()
        defaults.set(false, forKey: "autoYes")
        defaults.set(true, forKey: "hasSeenWelcome")
        let store = Store(directory: root, defaults: defaults, mobileResources: root)
        defer { store.stop() }
        func receive(_ value: [String: Any]) throws {
            store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: JSONSerialization.data(withJSONObject: value)))
        }
        try receive(["type": "hello", "sessionID": "orchard", "agent": "copilot",
                     "cwd": "/Projects/orchard", "title": "Orchard notes"])
        store.select("orchard")
        for state in ["empty", "one", "multiple", "sending", "uncertain", "automatic", "disconnected", "reconnecting"] {
            if state == "one" {
                try receive(["type": "request", "sessionID": "orchard", "request": [
                    "id": "review", "kind": "permission", "title": "Review the garden plan",
                    "detail": "Review this fictional plan before continuing.", "autoEligible": false, "questions": []
                ]])
            } else if state == "multiple" {
                try receive(["type": "hello", "sessionID": "garden", "agent": "copilot", "cwd": "/Projects/garden"])
                for id in ["planting", "watering"] {
                    try receive(["type": "request", "sessionID": "garden", "request": [
                        "id": id, "kind": "permission", "title": "Review \(id)", "detail": "A fictional request",
                        "autoEligible": false, "questions": []
                    ]])
                }
            } else if state == "sending" {
                store.sending.insert("review")
            } else if state == "uncertain" {
                try receive(["type": "error", "sessionID": "orchard", "requestID": "review",
                             "text": "No acknowledgment yet. Check before retrying."])
            } else if state == "automatic" {
                store.sending.insert("review")
                store.automaticallySending.insert("review")
            } else if state == "disconnected" {
                store.server.onDisconnect("orchard")
            } else if state == "reconnecting" {
                try receive(["type": "hello", "sessionID": "orchard", "agent": "copilot", "cwd": "/Projects/orchard"])
            }
            for dark in [false, true] {
                for size in [NSSize(width: 960, height: 620), NSSize(width: 1120, height: 750)] {
                    let host = NSHostingView(rootView: WorkOverview(store: store)
                        .foregroundStyle(Palette.ink).tint(Palette.accent)
                        .environment(\.colorScheme, dark ? .dark : .light))
                    host.sizingOptions = []
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = NSRect(origin: .zero, size: size)
                    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    defer { window.contentView = nil; window.close() }
                    for _ in 0..<4 {
                        host.layoutSubtreeIfNeeded()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    }
                    precondition(!window.isVisible && !window.isKeyWindow, "Synthetic captures must never show or focus a window")
                    let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let file = output.appendingPathComponent("\(state)-\(dark ? "dark" : "light")-\(Int(size.width)).png")
                    try bitmap.representation(using: .png, properties: [:])!.write(to: file)
                    let recognition = VNRecognizeTextRequest()
                    try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([recognition])
                    let sidebar = recognition.results!.filter { $0.boundingBox.midX < 232 / size.width }
                        .compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                    precondition(sidebar.contains("Needs attention") == !["empty", "disconnected", "reconnecting"].contains(state), "Indicator visibility: \(file.lastPathComponent)\n\(sidebar)")
                    if state != "empty" {
                        precondition(sidebar.contains("Review the garden plan"), "Current request remains readable: \(sidebar)")
                    }
                    if ["multiple", "sending", "uncertain", "automatic", "disconnected", "reconnecting"].contains(state) {
                        precondition(sidebar.contains("+2 additional requests"), "Count must remain fully readable: \(sidebar)")
                    } else {
                        precondition(!sidebar.contains("additional requests"), "No invented extra count: \(sidebar)")
                    }
                    if state == "sending" || state == "automatic" { precondition(sidebar.contains("Awaiting acknowledgment"), sidebar) }
                    if state == "uncertain" { precondition(sidebar.contains("Check reply delivery"), sidebar) }
                    if state == "disconnected" || state == "reconnecting" {
                        precondition(sidebar.contains("Pending request") && sidebar.contains("status unknown"), sidebar)
                        if state == "reconnecting" {
                            precondition(sidebar.contains("Awaiting update") && !store.attentionIsActionable, sidebar)
                        }
                        func luminance(_ color: NSColor) -> Double {
                            let rgb = color.usingColorSpace(.deviceRGB)!
                            func linear(_ value: CGFloat) -> Double {
                                value <= 0.04045 ? Double(value / 12.92) : pow(Double((value + 0.055) / 1.055), 2.4)
                            }
                            return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
                        }
                        let scale = Double(bitmap.pixelsWide) / size.width
                        let background = luminance(bitmap.colorAt(x: Int(4 * scale), y: Int(80 * scale))!)
                        var contrast = 1.0
                        for y in Int(65 * scale)..<Int(174 * scale) {
                            for x in Int(18 * scale)..<Int(214 * scale) {
                                let foreground = luminance(bitmap.colorAt(x: x, y: y)!)
                                contrast = max(contrast, (max(background, foreground) + 0.05) / (min(background, foreground) + 0.05))
                            }
                        }
                        precondition(contrast >= 4.5, "Unresolved current request must remain readable, not disabled-color text: \(contrast)")
                    }
                    print("Offscreen attention: \(file.lastPathComponent) passed")
                }
            }
        }
    }
}
