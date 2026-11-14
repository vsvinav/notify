import AppKit
import Carbon
import SwiftUI
import NotifyCore
import Vision

@main struct UIChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: "resources/Info.plist")), format: nil) as! [String: Any]
        precondition(plist["LSUIElement"] as? Bool != true, "Notify must be a normal Dock application, not a hidden menu-bar agent")
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("notify-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let suite = "notify-ui-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let store = Store(directory: fixtureRoot, defaults: defaults)
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
        let host = NSHostingView(rootView: RequestEditor(store: store, session: session, request: request)
            .padding(20).background(Palette.surface).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 410, height: 430),
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
        let warmSurface = NSColor(store.sessionSurface(session)).usingColorSpace(.sRGB)!
        precondition(warmSurface.redComponent > 0.50, "The approved notification needs a rich session color, not the rejected nearly-black tint")
        func luminance(_ color: NSColor) -> Double {
            func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
        }
        let noticeText = NSColor(srgbRed: 1, green: 234.0 / 255, blue: 223.0 / 255, alpha: 1)
        for color: UInt32 in [0xFFFFFF, 0xFFFF00, 0x00FF00, 0xF29A78, 0x408ED8, 0] {
            store.setColor(color, for: session)
            let surface = NSColor(store.sessionSurface(session)).usingColorSpace(.sRGB)!
            precondition((luminance(noticeText) + 0.05) / (luminance(surface) + 0.05) >= 4.5,
                         "User-selected session colors must keep notification detail text readable")
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
        precondition(descendants(dashboard).compactMap { $0 as? NSScrollView }.count >= 2,
                     "Session list and selected activity need independent scroll regions")
        print("Native workspace layout, activity selection and notification replay checks passed")
        if let argument = CommandLine.arguments.firstIndex(of: "--capture"), CommandLine.arguments.indices.contains(argument + 1) {
            let output = URL(fileURLWithPath: CommandLine.arguments[argument + 1], isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let visual = Store(directory: fixtureRoot.appendingPathComponent("visual"), defaults: defaults)
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
                try receive(["type": "capabilities", "sessionID": id, "activityFeed": true, "steering": true, "sessionAutoYes": true])
                try receive(["type": "state", "sessionID": id, "state": index > 5 ? "ready" : "working", "text": index > 5 ? "Agent idle" : "Reviewing the requested changes"])
                try receive(["type": "activity", "sessionID": id, "activity": [
                    "id": "tool-\(index)", "kind": "tool", "title": index == 0 ? "Read auth/refresh.ts" : "Inspect project files",
                    "detail": "Read the relevant implementation before making changes.", "status": "complete",
                    "timestamp": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-95))
                ]])
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
            func capture<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String) throws {
                let capture = NSHostingView(rootView: view)
                capture.sizingOptions = []
                window.contentView = capture
                capture.frame = NSRect(x: 0, y: 0, width: width, height: height)
                window.setContentSize(NSSize(width: width, height: height))
                for _ in 0..<12 {
                    capture.layoutSubtreeIfNeeded()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.025))
                }
                precondition(capture.bounds.size == NSSize(width: width, height: height), "Capture must match its requested shipping size")
                if name == "floating-diff.png" {
                    let scroll = descendants(capture).compactMap { $0 as? NSScrollView }.first!
                    precondition(scroll.contentSize.height > 300, "Expanded diffs must use available space, not collapse to a tiny scroll strip")
                }
                let bitmap = capture.bitmapImageRepForCachingDisplay(in: capture.bounds)!
                capture.cacheDisplay(in: capture.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
                if name == "control-center-connections.png" {
                    let recognition = VNRecognizeTextRequest()
                    recognition.recognitionLevel = .accurate
                    try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([recognition])
                    let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                    precondition(text.contains("Connected") && text.contains("Not connected") && text.contains("Disconnected"),
                                 "Rendered connection groups and disconnected labels must be readable. Found: \(text)")
                }
            }
            try capture(DashboardView(store: visual), width: 1120, height: 800, name: "control-center.png")
            try capture(DashboardView(store: visual), width: 960, height: 620, name: "control-center-small.png")
            visual.server.onDisconnect("visual-6")
            visual.server.onDisconnect("visual-7")
            try capture(DashboardView(store: visual), width: 1120, height: 800, name: "control-center-connections.png")
            try capture(FloatingView(store: visual, openCenter: {}), width: 420, height: 560, name: "floating-command.png")
            window.makeKey()
            let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                         isARepeat: false, keyCode: 36)!
            precondition(window.performKeyEquivalent(with: enter), "Return must invoke the focused notification's Allow once action")
            precondition(visual.requestErrors["visual-request"] != nil, "Return must dispatch the exact pending request (the fixture has no transport)")
            visual.requestErrors.removeValue(forKey: "visual-request")
            guard let instructions = descendants(window.contentView!).compactMap({ $0 as? NSTextField }).first(where: {
                $0.placeholderString?.hasPrefix("Tell Copilot") == true
            }) else { preconditionFailure("Denial instructions must be a native editable field") }
            window.makeFirstResponder(instructions)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            _ = window.performKeyEquivalent(with: enter)
            precondition(visual.requestErrors["visual-request"] == nil, "Return must not approve while editing denial instructions")
            try capture(FloatingView(store: visual, openCenter: {}), width: 420, height: 500, name: "floating-short-screen.png")
            visual.setColor(0x9654CE, for: visual.selected!)
            visual.floatingExpanded = true
            try capture(FloatingView(store: visual, openCenter: {}), width: 600, height: 760, name: "floating-expanded.png")
            try receive(["type": "error", "sessionID": "visual-0", "requestID": "visual-request",
                         "text": "Reply could not be delivered. Check the agent connection before trying again."])
            try capture(FloatingView(store: visual, openCenter: {}), width: 600, height: 760, name: "floating-error.png")
            visual.requestErrors.removeValue(forKey: "visual-request")
            visual.sending.insert("visual-request")
            try capture(FloatingView(store: visual, openCenter: {}), width: 600, height: 760, name: "floating-sending.png")
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
            visual.floatingExpanded = false
            visual.replyWorkspace.next(requestIDs: ["visual-question"])
            visual.replyWorkspace.drafts["visual-question"] = ReplyDraft(freeText: ["0": "Use banker's rounding for the final total."])
            try capture(FloatingView(store: visual, openCenter: {}), width: 420, height: 560, name: "floating-question.png")
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
                ("response", "assistant", "Agent response", "I found a focus-order mismatch in the overflow menu. Next I will update the keyboard navigation test.")
            ] {
                try receive(["type": "activity", "sessionID": "visual-2", "activity": [
                    "id": id, "kind": kind, "title": title, "detail": text, "status": "complete",
                    "timestamp": ISO8601DateFormatter().string(from: Date())
                ]])
            }
            try capture(DashboardView(store: visual), width: 1120, height: 800, name: "control-center-activity.png")
            visual.stop()
            window.contentView = dashboard
        }
        let appDelegate = AppDelegate(store: store, backgroundLaunch: true)
        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
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
        NSApp.keyWindow?.makeFirstResponder(nil)
        store.onAttentionChange?()
        func sendReturn(_ kind: UInt32, key: UInt32 = UInt32(kVK_Return)) {
            var event: EventRef?
            precondition(CreateEvent(nil, OSType(kEventClassKeyboard), kind, 0, 0, &event) == noErr)
            var identity = EventHotKeyID(signature: 0x4e745274, id: key)
            precondition(SetEventParameter(event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID),
                                          MemoryLayout<EventHotKeyID>.size, &identity) == noErr)
            precondition(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr,
                         "A visible notification must own the global Return hotkey")
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
        let replyPanel = NSApp.windows.compactMap { $0 as? ReplyPanel }.first!
        for _ in 0..<8 {
            replyPanel.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let instructions = descendants(replyPanel.contentView!).compactMap { $0 as? NSTextField }.first {
            $0.placeholderString?.hasPrefix("Tell Copilot") == true
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
        replyPanel.makeFirstResponder(nil)
        store.floatingEnabled = false
        assertReturnReleased("Hidden notifications must release their global keys")
        let keyboardResolved = try JSONSerialization.data(withJSONObject: [
            "type": "resolved", "sessionID": session.id, "requestID": "keyboard-question", "decision": "answer"
        ])
        store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: keyboardResolved))
        precondition(NSApp.dockTile.badgeLabel == String(previousWaiting + 1), "Snoozing a card must not erase its pending Dock count")
        store.automaticallySending.insert("dock-test")
        store.onAttentionChange?()
        precondition(NSApp.dockTile.badgeLabel == (previousWaiting == 0 ? nil : String(previousWaiting)), "Automatic replies must not flash a waiting badge")
        precondition(!replyPanel.becomesKeyOnlyIfNeeded && !replyPanel.hidesOnDeactivate,
                     "Clicking a card must permit keyboard focus without hiding it on app switches")
        center.performClose(nil)
        precondition(!center.isVisible && !appDelegate.applicationShouldTerminateAfterLastWindowClosed(NSApp), "Closing the workspace must keep monitoring")
        NSApp.activate()
        pumpNativeEvents()
        _ = appDelegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        precondition(center.isVisible, "Dock reopening must restore a closed workspace")
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
