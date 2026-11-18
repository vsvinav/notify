import AppKit
import SwiftUI
import NotifyCore

enum AgentPerformanceChecks {
    private struct ChatPerformanceFixture: View {
        @ObservedObject var store: Store
        var body: some View {
            AgentChatView(store: store, session: store.registry.sessions["chat-performance"]!, agentID: "helper")
                .padding(22)
        }
    }

    @MainActor static func runChat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notify-chat-performance-" + UUID().uuidString)
        let suite = "notify-chat-performance-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = Store(directory: root, defaults: defaults)
        defer {
            store.stop()
            defaults.removePersistentDomain(forName: suite)
            try! FileManager.default.removeItem(at: root)
        }
        func receive(_ packet: [String: Any]) throws {
            store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: JSONSerialization.data(withJSONObject: packet)))
        }
        try receive(["type": "hello", "sessionID": "chat-performance", "agent": "copilot", "cwd": "/Projects/fixture"])
        try receive(["type": "capabilities", "sessionID": "chat-performance",
                     "steering": true, "subagentChat": true, "subagentStop": true])
        try receive(["type": "team", "sessionID": "chat-performance", "team": [
            "agents": [["id": "helper", "name": "Fixture reviewer", "task": "Review fixture", "status": "idle"]],
            "runningCount": 0, "idleCount": 1, "truncated": false
        ]])
        for index in 0..<20 {
            try receive(["type": "hello", "sessionID": "background-\(index)", "agent": "copilot", "cwd": "/Projects/background-\(index)"])
        }
        let section = """
        ## Review findings

        This synthetic response contains **important details**, `inline code`, and a [reference](https://example.com).

        - Preserve the current behavior.
        - Check the surrounding callers.
        - Explain the observable result.

        ```swift
        let result = calculate(input)
        precondition(result.isValid)
        ```

        """
        for index in 0..<8 {
            try receive(["type": "activity", "sessionID": "chat-performance", "activity": [
                "id": "reply-\(index)", "kind": "assistant", "agentID": "helper", "title": "Response",
                "detail": String(repeating: section, count: 120), "status": "complete",
                "timestamp": "2026-11-15T12:00:\(String(format: "%02d", index))Z"
            ]])
        }
        let session = store.registry.sessions["chat-performance"]!
        precondition(session.activity.entries.count == 8)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 760, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ChatPerformanceFixture(store: store))
        host.sizingOptions = []
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        guard let scroll = scrollViews(host).max(by: {
            ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
        }) else { preconditionFailure("Subagent chat must contain a scroll view") }
        NSLog("Chat scroll geometry: document %.0f, viewport %.0f, initial offset %.0f",
              scroll.documentView?.frame.height ?? 0, scroll.contentView.bounds.height, scroll.contentView.bounds.origin.y)
        let cpuStart = clock()
        var worst = 0.0, total = 0.0, worstDelivery = 0.0
        var delivered = 0
        for index in 0..<60 {
            let start = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                do {
                    let id = "scroll-request-\(index)"
                    try receive(["type": "request", "sessionID": "background-0", "request": [
                        "id": id, "kind": "permission", "title": "Synthetic scrolling check",
                        "detail": "", "autoEligible": false, "questions": []
                    ]])
                    precondition(store.pending.contains { $0.request.id == id })
                    worstDelivery = max(worstDelivery, ProcessInfo.processInfo.systemUptime - start)
                    delivered += 1
                    try receive(["type": "resolved", "sessionID": "background-0", "requestID": id])
                } catch { preconditionFailure("Synthetic request delivery failed: \(error)") }
            }
            for background in 0..<3 {
                try receive(["type": "activity", "sessionID": "background-\(background)", "activity": [
                    "id": "stream", "kind": "assistant", "title": "Background response",
                    "detail": "Background progress \(index)", "status": "running", "timestamp": "2026-11-15T12:01:00Z"
                ]])
            }
            let next = max(0, scroll.contentView.bounds.origin.y - 140)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: next))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            worst = max(worst, elapsed)
            total += elapsed
        }

        NSLog("Subagent chat 60 scroll steps: total %.3fs, worst %.3fs, CPU %.3fs",
              total, worst, Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC))
        NSLog("Synthetic notification delivery during scrolling: %d/60, worst %.3fs", delivered, worstDelivery)
        precondition(delivered == 60 && worstDelivery < 0.100, "Scrolling must not starve pending-notification delivery")
        precondition(worst < 0.100, "Subagent scrolling must not block the UI/notification thread for 100ms")
    }

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
