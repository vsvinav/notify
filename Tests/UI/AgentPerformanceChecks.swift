import AppKit
import SwiftUI
import NotifyCore

enum AgentPerformanceChecks {
    @MainActor static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notify-performance-" + UUID().uuidString)
        let suite = "notify-performance-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = Store(directory: root, defaults: defaults)
        defer {
            store.stop()
            defaults.removePersistentDomain(forName: suite)
            try! FileManager.default.removeItem(at: root)
        }
        func receive(_ packet: [String: Any]) throws {
            store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: JSONSerialization.data(withJSONObject: packet)))
        }
        try receive(["type": "hello", "sessionID": "performance", "agent": "copilot", "cwd": "/Projects/fixture"])
        try receive(["type": "state", "sessionID": "performance", "state": "working"])
        try receive(["type": "team", "sessionID": "performance", "team": [
            "agents": (0..<12).map { ["id": "worker-\($0)", "name": "Helper \($0)", "task": "Synthetic task", "status": $0 == 0 ? "running" : "idle"] },
            "runningCount": 1, "idleCount": 11, "truncated": false
        ]])
        for index in 0..<300 {
            try receive(["type": "activity", "sessionID": "performance", "activity": [
                "id": "message-\(index)", "kind": "assistant", "title": "Response", "detail": "Synthetic reply \(index)",
                "status": "complete", "timestamp": index.isMultiple(of: 2) ? "2026-01-01T12:00:00.123Z" : "2026-01-01T12:00:00Z"
            ]])
        }
        let session = store.registry.sessions["performance"]!
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 320, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SubagentTeamView(store: store, session: session).padding(16))
        host.sizingOptions = []
        window.contentView = host
        store.centerVisible = true
        window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let cpuStart = clock()
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        let cpuSeconds = Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC)
        NSLog("Visible team CPU over 3s: %.3fs", cpuSeconds)
        precondition(cpuSeconds < 0.5, "Agent animation must not keep a CPU core busy between its eight updates per second")
        store.centerVisible = false
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        let staticStart = clock()
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        NSLog("Paused team CPU over 3s: %.3fs", Double(clock() - staticStart) / Double(CLOCKS_PER_SEC))

        let chat = AgentChatView(store: store, session: session, agentID: nil)
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<20 { precondition(chat.rows.count == 300) }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        NSLog("20 full-history chat projections: %.3fs", elapsed)
        precondition(elapsed < 0.5, "Repeated chat projection must not monopolize the UI thread")
        precondition(chat.rows.prefix(150).allSatisfy { $0.date == Date(timeIntervalSince1970: 1767268800) },
                     "Whole-second and fractional timestamps must still sort chronologically")
        precondition(AgentIllustration(presence: .resting, time: 1) == AgentIllustration(presence: .resting, time: 2),
                     "Unchanged idle poses must not redraw on every animation tick")
        precondition(AgentIllustration(presence: .working, time: 0) != AgentIllustration(presence: .working, time: 0.25),
                     "Typing must retain visible hand movement")
        precondition(AgentIllustration(presence: .resting, time: 0) != AgentIllustration(presence: .resting, time: 1),
                     "Idle blink transitions must remain visible")
    }
}
