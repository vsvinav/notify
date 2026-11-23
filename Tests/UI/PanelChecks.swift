import AppKit
import SwiftUI
import NotifyCore
import Vision

private final class PanelDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func register(defaults registration: [String: Any]) { values.merge(registration) { existing, _ in existing } }
}

enum PanelChecks {
    static let feed = """
    {"status":200,"data":{"available":true,"panel":{"version":1,"title":"Example pipeline","tabs":[
    {"id":"work","label":"Work","sections":[{"title":"Review","items":[
    {"id":"example","title":"Make setup easier to follow","subtitle":"A fictional first-run flow with clearer connection steps.","tone":"warn","actions":[{"id":"review","label":"Review instruction","style":"primary"}],"log":{"entries":[{"at":"14:32","text":"Draft ready. Waiting for a human review."}],"truncated":true}},
    {"id":"duplicate","title":"First duplicate","actions":[]},{"id":"duplicate","title":"Second duplicate","actions":[]}]}],
    "track":{"version":1,"title":"Work stages","stages":[{"id":"inbox","label":"Inbox","kind":"normal"},{"id":"review","label":"Review","kind":"gate"}],"placements":[{"itemId":"example","stageId":"review"}]}},
    {"id":"todo","label":"To do","sections":[],"form":{"version":1,"actionId":"add","title":"Add a todo","submitLabel":"Preview todo","minLength":2,"maxLength":300,"placeholder":"Describe the next step"}}]}}}
    """
    static let authority = """
    {"status":200,"data":{"ok":true,"confirm":"Send this instruction to the destination?","confirmationToken":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}
    """

    private static func longTrackFeed(includeForm: Bool) throws -> String {
        var envelope = try JSONSerialization.jsonObject(with: Data(feed.utf8)) as! [String: Any]
        var body = envelope["data"] as! [String: Any]
        var data = body["panel"] as! [String: Any]
        var tabs = data["tabs"] as! [[String: Any]]
        var placements = [["itemId": "example", "stageId": "stage-24"]]
        if includeForm {
            var sections = tabs[0]["sections"] as! [[String: Any]]
            let example = (sections[0]["items"] as! [[String: Any]])[0]
            sections[0]["items"] = [
                ["id": "start", "title": "Start example work", "subtitle": "A fictional first stage.", "actions": []], example
            ]
            tabs[0]["sections"] = sections
            tabs[0]["form"] = tabs[1]["form"]
            tabs = [tabs[0]]
            placements.insert(["itemId": "start", "stageId": "stage-1"], at: 0)
        }
        tabs[0]["track"] = ["version": 1, "title": "Long provider workflow",
            "stages": (1...24).map { ["id": "stage-\($0)", "label": "Example stage \($0)", "kind": "normal"] },
            "placements": placements]
        data["tabs"] = tabs; body["panel"] = data; envelope["data"] = body
        return String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
    }

    @MainActor static func run() throws {
        let root = URL(fileURLWithPath: ".build/panel-fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = PanelDefaults()
        var time: TimeInterval = 100
        var calls: [Data] = []
        var callbacks: [(Result<Data, Error>) -> Void] = []
        let panel = PanelConnection(defaults: defaults, resources: root, directory: root,
            executor: { data, _, done in calls.append(data); callbacks.append(done); return {} }, clock: { time })
        defer { panel.stop() }
        var checks = 0
        func expect(_ value: Bool, _ message: String) {
            checks += 1
            precondition(value, message)
        }
        func respond(_ value: String) { callbacks.removeFirst()(.success(Data(value.utf8))) }
        panel.setVisible(true); panel.refresh()
        expect(!panel.enabled && calls.isEmpty, "Off by default means no helper or discovery")
        panel.setEnabled(true)
        expect(calls.count == 1, "Visible enable reads immediately")
        respond(feed)
        expect(panel.isFresh && panel.feed?.tabs.count == 2, "Read establishes local freshness")
        expect(panel.feed!.tabs[0].unplacedItems.count == 2, "Unplaced duplicates survive")
        expect(Set(panel.feed!.tabs[0].items.map(\.key)).count == 3, "Display IDs cannot collide")
        panel.selectTab("todo")
        let raw = "  hello 👋\n"
        panel.setDraft(raw, tabID: "todo", actionID: "add")
        panel.preview(actionID: "add", text: raw)
        respond(authority)
        expect(panel.confirmation != nil && panel.canSend, "Authoritative preview permits send")
        panel.cancelPreview()
        expect(calls.count == 2 && panel.draft(tabID: "todo", actionID: "add") == raw, "Cancel sends nothing and preserves exact draft")
        panel.preview(actionID: "add", text: raw)
        respond(authority)
        panel.setDraft(raw + "x", tabID: "todo", actionID: "add")
        expect(!panel.canSend, "Editing invalidates preview")
        panel.preview(actionID: "add", text: String(repeating: "👋", count: 151))
        expect(calls.count == 3, "Length limits count UTF-16")
        panel.setDraft(raw, tabID: "todo", actionID: "add")
        panel.preview(actionID: "add", text: raw)
        respond(authority)
        panel.sendPreview(); panel.sendPreview()
        expect(calls.count == 5 && panel.receipt?.delivery == .sending, "Send consumes authority and persists receipt before dispatch")
        let sent = try JSONSerialization.jsonObject(with: calls.last!) as! [String: Any]
        expect((sent["input"] as? [String: Any])?["text"] as? String == raw, "Send preserves raw text")
        respond(#"{"status":504,"data":{"ok":false}}"#)
        expect(panel.receipt?.delivery == .unknown, "Ambiguous send stays unknown")
        panel.setEnabled(false)
        expect(panel.receipt?.delivery == .unknown, "Off preserves uncertainty")
        let restored = PanelConnection(defaults: defaults, resources: root, directory: root, executor: { _, _, _ in fatalError("Off must not execute") }, clock: { time })
        expect(!restored.enabled && restored.receipt?.delivery == .unknown, "Receipt and disabled preference survive restart")
        restored.stop()
        panel.setEnabled(true); respond(feed)
        panel.acknowledgeUnknown()
        expect(panel.receipt == nil && !panel.canSend, "Acknowledgment never resends")
        respond(feed)
        panel.selectTab("todo")
        panel.preview(actionID: "add", text: raw)
        respond(#"{"status":200,"data":{"ok":true,"confirm":"Demo","demo":true}}"#)
        expect(!panel.canSend, "Demo/tokenless previews have no authority")
        panel.preview(actionID: "add", text: raw); respond(authority)
        time += 31; panel.tick()
        expect(!panel.canSend, "Expiry consumes authority")
        panel.setVisible(false)
        let count = calls.count
        time += 100; panel.tick()
        expect(calls.count == count, "Hidden polling pauses")
        if !callbacks.isEmpty { respond(feed) }
        panel.setVisible(true)
        expect(calls.count == count + 1 && !panel.isFresh, "Reopen never trusts cached freshness")
        panel.setVisible(false); respond(feed)
        expect(!panel.isFresh, "Stale generation response cannot establish freshness")
        panel.setVisible(true); respond(feed)
        panel.selectTab("todo")
        panel.preview(actionID: "add", text: raw)
        respond(#"{"status":200,"data":{"ok":true,"confirm":"No token"}}"#)
        expect(!panel.canSend, "Missing token cannot authorize")
        panel.preview(actionID: "add", text: raw)
        respond(authority.replacingOccurrences(of: "aaaaaaaaaaa\"}", with: "aaaaaaaaaaa\\n\"}"))
        expect(!panel.canSend, "Token must be exactly 43 URL-safe bytes, without newline")
        panel.preview(actionID: "add", text: raw)
        let oldPreview = callbacks.first!
        panel.setDraft("Edited", tabID: "todo", actionID: "add")
        respond(authority)
        expect(!panel.canSend, "Editing during preview rejects delayed authority")
        panel.preview(actionID: "add", text: "Edited")
        oldPreview(.success(Data(authority.utf8)))
        expect(panel.busy, "Duplicate stale callback cannot release a different child")
        respond(authority)
        panel.setSleeping(true)
        expect(!panel.canSend && !panel.isFresh, "Sleep invalidates freshness and authority")
        panel.setSleeping(false); respond(feed)
        panel.selectTab("todo")
        panel.refresh()
        respond(feed.replacingOccurrences(of: "\"actionId\":\"add\"", with: "\"actionId\":\"replacement\""))
        expect(panel.draft(tabID: "todo", actionID: "add") == "Edited" &&
               panel.draft(tabID: "todo", actionID: "replacement").isEmpty, "Removed form keeps old draft without retargeting")
        panel.preview(actionID: "add", text: "Edited")
        expect(!panel.busy, "Removed action cannot send the old draft")
        panel.refresh(); respond(feed)
        panel.selectTab("todo"); panel.preview(actionID: "add", text: "Edited"); respond(authority)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("panel-action.json"), withIntermediateDirectories: false)
        let beforeFailure = calls.count
        panel.sendPreview()
        expect(calls.count == beforeFailure && panel.error != nil, "Receipt write failure blocks dispatch")
        try FileManager.default.removeItem(at: root.appendingPathComponent("panel-action.json"))
        try Data("invalid".utf8).write(to: root.appendingPathComponent("panel-action.json"))
        let invalid = PanelConnection(defaults: defaults, resources: root, directory: root, executor: { _, _, _ in fatalError() })
        expect(invalid.error != nil && !invalid.actionsAllowed, "Invalid receipt blocks actions")
        invalid.stop()
        try FileManager.default.removeItem(at: root.appendingPathComponent("panel-action.json"))
        var pending = PanelReceipt(id: UUID(), createdAt: Date(), delivery: .sending)
        try JSONEncoder().encode(pending).write(to: root.appendingPathComponent("panel-action.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("panel-action.json").path)
        let restarted = PanelConnection(defaults: defaults, resources: root, directory: root, executor: { _, _, _ in fatalError() })
        expect(restarted.enabled && restarted.receipt?.delivery == .unknown, "Saved-on does not read hidden; restored sending is unknown")
        restarted.stop()
        pending.delivery = .accepted
        try JSONEncoder().encode(pending).write(to: root.appendingPathComponent("panel-action.json"))
        let accepted = PanelConnection(defaults: defaults, resources: root, directory: root, executor: { _, _, _ in fatalError() })
        expect(accepted.receipt?.delivery == .accepted, "Acceptance persists without inventing completion")
        accepted.stop()
        let malformedTrack = feed.replacingOccurrences(of: "\"itemId\":\"example\"", with: "\"itemId\":\"duplicate\"")
        let fallback = try JSONDecoder().decode(PanelResponse.self, from: Data(malformedTrack.utf8))
        expect(fallback.data.panel!.tabs[0].validTrack == nil && fallback.data.panel!.tabs[0].unplacedItems.count == 3,
               "Ambiguous placements use complete generic fallback")
        let routingDefaults = PanelDefaults()
        routingDefaults.set(false, forKey: "autoYes"); routingDefaults.set(true, forKey: "hasSeenWelcome")
        let store = Store(directory: root.appendingPathComponent("routing"), defaults: routingDefaults, mobileResources: root)
        defer { store.stop() }
        func receive(_ value: [String: Any]) throws {
            store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: JSONSerialization.data(withJSONObject: value)))
        }
        try receive(["type": "hello", "sessionID": "fictional", "agent": "copilot", "cwd": "/Projects/fictional"])
        try receive(["type": "request", "sessionID": "fictional", "request": [
            "id": "review", "kind": "permission", "title": "Review example", "detail": "Fictional", "autoEligible": false, "questions": []
        ]])
        store.select("fictional")
        store.workspaceDestination = .dashboard
        store.reconcileSelection(in: [])
        expect(store.workspaceDestination == .dashboard && store.selectedID == "fictional", "Background filtered reconciliation cannot steal Dashboard")
        store.openAttentionRequest()
        expect(store.workspaceDestination == .sessions && store.selectedID == "fictional", "Same-session attention routes to Sessions")
        store.workspaceDestination = .dashboard; store.select("fictional")
        expect(store.workspaceDestination == .sessions, "Explicit selection always exits Dashboard")
        let revision = store.sessionSelectionRevision
        store.select("fictional")
        expect(store.sessionSelectionRevision != revision, "Same-session selection notifies filtered sidebar observers")
        store.panel.setEnabled(true); store.workspaceDestination = .dashboard
        store.waitingOnly = true; store.panel.setEnabled(false)
        expect(store.workspaceDestination == .sessions && store.waitingOnly && store.selectedID == "fictional",
               "Off routes Sessions without clearing session selection or filter")
        try transitionChecks(root: root)
        try processChecks(root: root)
        if let source = ProcessInfo.processInfo.environment["NOTIFY_PANEL_HELPER_SOURCE"] {
            try adapterChecks(root: root, source: URL(fileURLWithPath: source))
        }
        print("Panel checks passed (\(checks))")
    }

    @MainActor private static func transitionChecks(root: URL) throws {
        let directory = root.appendingPathComponent("transitions")
        var time: TimeInterval = 0
        var count = 0
        var callback: ((Result<Data, Error>) -> Void)?
        let panel = PanelConnection(defaults: PanelDefaults(), resources: root, directory: directory,
            executor: { _, _, done in count += 1; callback = done; return {} }, clock: { time })
        defer { panel.stop() }
        func respond(_ value: String) { callback?(.success(Data(value.utf8))) }
        panel.setEnabled(true)
        precondition(count == 0, "Enabled but hidden stays idle")
        panel.setVisible(true); respond(#"{"status":200,"data":{"available":false,"reason":"Fictional provider absent"}}"#)
        time = 59; panel.tick(); precondition(count == 1)
        time = 60; panel.tick(); precondition(count == 2, "Missing provider uses 60-second backoff")
        respond(feed); time = 74; panel.tick(); precondition(count == 2)
        time = 75; panel.tick(); precondition(count == 3, "Fresh provider polls after 15 seconds")
        panel.refresh(); precondition(count == 3, "A live child excludes overlapping refreshes")
        respond(feed)
        panel.preview(actionID: "review"); respond(authority)
        time = 91; panel.tick(); precondition(count == 4 && panel.canSend, "A confirmation pauses polling")
        panel.refresh(); precondition(count == 4, "Refresh cannot silently replace sheet authority")
        panel.sendPreview()
        precondition(count == 5)
        let receiptPath = directory.appendingPathComponent("panel-action.json")
        try FileManager.default.removeItem(at: receiptPath)
        try FileManager.default.createDirectory(at: receiptPath, withIntermediateDirectories: false)
        respond(#"{"status":200,"data":{"ok":true,"sent":true}}"#)
        precondition(panel.receipt?.delivery == .unknown && panel.error != nil && !panel.actionsAllowed,
                     "Receipt update failure retains conservative uncertainty")
        let ambiguous = PanelConnection(defaults: PanelDefaults(), resources: root, directory: root.appendingPathComponent("malformed"),
            executor: { _, _, done in done(.success(Data((feed + feed).utf8))); return {} })
        ambiguous.setEnabled(true); ambiguous.setVisible(true)
        precondition(!ambiguous.isFresh && !ambiguous.busy, "Exactly one response JSON is required")
        ambiguous.stop()
        let stoppedDirectory = root.appendingPathComponent("stopped-send")
        let pending = PanelConnection(defaults: PanelDefaults(), resources: root, directory: stoppedDirectory,
            executor: { _, _, done in callback = done; return {} })
        pending.setEnabled(true); pending.setVisible(true); respond(feed)
        pending.preview(actionID: "review"); respond(authority); pending.sendPreview(); pending.stop()
        precondition(pending.receipt?.delivery == .unknown && !pending.canSend, "Stop never claims a sent action was cancelled")
        respond(#"{"status":200,"data":{"ok":true,"sent":true,"demo":true}}"#)
        precondition(pending.receipt?.delivery == .unknown, "A demo response never proves delivery")
        print("Polling, receipt-update, stop and malformed-response checks passed")
    }

    @MainActor private static func processChecks(root: URL) throws {
        let resources = root.appendingPathComponent("process")
        let scripts = resources.appendingPathComponent("mobile/src")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let script = scripts.appendingPathComponent("panel-main.mjs")
        func run(_ source: String, timeout: TimeInterval = 2) throws -> Result<Data, Error> {
            try Data(source.utf8).write(to: script)
            var result: Result<Data, Error>?
            let cancel = PanelProcess.run(resources: resources, input: Data(#"{"type":"read"}"#.utf8), timeout: timeout) { result = $0 }
            let end = Date().addingTimeInterval(timeout + 3)
            while result == nil && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            if result == nil { cancel(); fatalError("Owned helper failed to finish within bound") }
            return result!
        }
        let safe = try run("""
        import fs from 'node:fs';
        const input=JSON.parse(fs.readFileSync(0,'utf8'));
        if(input.type!=='read')process.exit(2);
        const extra=Object.keys(process.env).filter(k=>!['HOME','PATH','LANG','TMPDIR','NODE_TLS_REJECT_UNAUTHORIZED','NOTIFY_PANEL_FILE','__CF_USER_TEXT_ENCODING'].includes(k));
        console.log(JSON.stringify({status:200,data:{available:false,reason:extra.length?extra.join(','):'Synthetic only'}}));
        """)
        guard case .success(let data) = safe else { fatalError("Safe fake helper failed: \(safe)") }
        let response = try JSONDecoder().decode(PanelResponse.self, from: data)
        precondition(response.data.reason == "Synthetic only", response.data.reason ?? "missing")
        for source in [
            "process.stdout.write('x'.repeat(400000));setInterval(()=>{},100);",
            "process.stderr.write('x'.repeat(9000));setInterval(()=>{},100);",
            "process.on('SIGTERM',()=>{});setInterval(()=>{},100);",
            "process.stdout.write('{}');process.exit(3);"
        ] {
            let result = try run(source, timeout: 0.2)
            if case .success = result { fatalError("Process failure accepted") }
        }
        let closed = try run("process.exit(0);")
        if case .success(let data) = closed { precondition(data.isEmpty) }
        print("Owned fake-helper process checks passed")
    }

    @MainActor private static func adapterChecks(root: URL, source: URL) throws {
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("panel-main.mjs").path) else {
            throw NSError(domain: "PanelChecks", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "NOTIFY_PANEL_HELPER_SOURCE must name the helper src directory, not its checkout root."])
        }
        let resources = root.appendingPathComponent("adapter")
        let mobile = resources.appendingPathComponent("mobile")
        try FileManager.default.createDirectory(at: mobile, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: mobile.appendingPathComponent("src"), withDestinationURL: source)
        let discovery = root.appendingPathComponent("synthetic-panel.json")
        let fixture = root.appendingPathComponent("synthetic-provider.mjs")
        let payload = try JSONSerialization.jsonObject(with: Data(feed.utf8)) as! [String: Any]
        let panelJSON = String(decoding: try JSONSerialization.data(withJSONObject: (payload["data"] as! [String: Any])["panel"]!), as: UTF8.self)
        let code = """
        import http from 'node:http'; import fs from 'node:fs';
        const token='fixture-only-token-aaaaaaaaaaaaaaaa', confirmation='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        const panel=\(panelJSON);
        let preview, sends=0;
        const server=http.createServer(async(req,res)=>{
          if(req.headers.authorization!==`Bearer ${token}`){res.writeHead(403);res.end('{}');return}
          res.setHeader('Content-Type','application/json');
          if(req.method==='GET'){res.end(JSON.stringify(panel));return}
          let body='';for await(const chunk of req)body+=chunk;
          const input=JSON.parse(body);
          if(input.preview){preview=input;res.end(JSON.stringify({ok:true,confirm:'Synthetic destination only',confirmationToken:confirmation}));return}
          if(!preview||input.text!==preview.text||input.actionId!==preview.actionId||input.confirmationToken!==confirmation||++sends!==1){res.writeHead(400);res.end('{}');return}
          preview=null;res.end(JSON.stringify({ok:true,sent:true}));
        });
        server.listen(0,'127.0.0.1',()=>fs.writeFileSync(process.argv[2],JSON.stringify({port:server.address().port,token}),{mode:0o600}));
        setTimeout(()=>server.close(),12000).unref();
        """
        try Data(code.utf8).write(to: fixture)
        guard let node = AgentSetup.findExecutable("node", path: AgentSetup.searchPath) else { fatalError("Node missing") }
        let provider = Process()
        provider.executableURL = node; provider.arguments = [fixture.path, discovery.path]
        provider.environment = ["HOME": root.path, "PATH": AgentSetup.searchPath, "NODE_TLS_REJECT_UNAUTHORIZED": "1"]
        provider.standardInput = FileHandle.nullDevice
        provider.standardOutput = FileHandle.nullDevice; provider.standardError = FileHandle.nullDevice
        try provider.run()
        defer {
            if provider.isRunning { provider.terminate() }
            provider.waitUntilExit()
        }
        let ready = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: discovery.path) && Date() < ready {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(provider.isRunning && FileManager.default.fileExists(atPath: discovery.path), "Owned synthetic provider did not become ready")
        let old = ProcessInfo.processInfo.environment["NOTIFY_PANEL_FILE"]
        setenv("NOTIFY_PANEL_FILE", discovery.path, 1)
        defer { if let old { setenv("NOTIFY_PANEL_FILE", old, 1) } else { unsetenv("NOTIFY_PANEL_FILE") } }
        let defaults = PanelDefaults()
        let panel = PanelConnection(defaults: defaults, resources: resources, directory: root.appendingPathComponent("adapter-receipt"))
        defer { panel.stop() }
        func wait() {
            let end = Date().addingTimeInterval(5)
            while panel.busy && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            precondition(!panel.busy, "Synthetic adapter operation did not finish")
        }
        panel.setEnabled(true); panel.setVisible(true); wait()
        precondition(panel.isFresh && panel.feed?.title == "Example pipeline")
        panel.selectTab("todo")
        let raw = "  synthetic 👋\n"
        panel.setDraft(raw, tabID: "todo", actionID: "add")
        panel.preview(actionID: "add", text: raw); wait()
        precondition(panel.canSend)
        panel.sendPreview(); panel.sendPreview(); wait()
        precondition(panel.receipt?.delivery == .accepted && panel.draft(tabID: "todo", actionID: "add") == raw)
        let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("adapter-receipt/panel-action.json"))) as! [String: Any]
        precondition(Set(receipt.keys) == Set(["id", "createdAt", "delivery"]), "Receipt must never include tokens, data or draft")
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("adapter-receipt/panel-action.json").path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        print("Real adapter with owned synthetic loopback provider: read, exact-text preview/send, one acceptance passed")
    }

    @MainActor static func captureOffscreen() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: ".build/panel-render-fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NOTIFY_PANEL_CAPTURES"] ?? ".build/panel-captures", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let defaults = PanelDefaults()
        defaults.set(false, forKey: "autoYes"); defaults.set(true, forKey: "hasSeenWelcome")
        var completion: ((Result<Data, Error>) -> Void)?
        let store = Store(directory: root, defaults: defaults, mobileResources: root,
                          panelExecutor: { _, _, done in completion = done; return {} })
        defer { store.stop() }
        func receive(_ value: [String: Any]) throws {
            store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: JSONSerialization.data(withJSONObject: value)))
        }
        try receive(["type": "hello", "sessionID": "example-session", "agent": "copilot", "cwd": "/Projects/example"])
        try receive(["type": "request", "sessionID": "example-session", "request": [
            "id": "example-review", "kind": "permission", "title": "Review example command",
            "detail": "A fictional request", "autoEligible": false, "questions": []
        ]])
        let panel = store.panel
        panel.setEnabled(true); store.workspaceDestination = .dashboard; store.centerVisible = true
        for state in ["missing-provider", "empty-feed", "combined", "dashboard", "todo", "confirmation", "fallback", "lower-stage", "unavailable", "unknown", "settings-off"] {
            panel.refresh()
            var response = feed
            if state == "missing-provider" {
                response = #"{"status":200,"data":{"available":false,"reason":"Fictional provider is not running."}}"#
            } else if state == "empty-feed" {
                response = #"{"status":200,"data":{"available":true,"panel":{"version":1,"tabs":[]}}}"#
            } else if state == "fallback" {
                response = feed.replacingOccurrences(of: "\"itemId\":\"example\"", with: "\"itemId\":\"duplicate\"")
            } else if state == "lower-stage" || state == "combined" {
                response = try longTrackFeed(includeForm: state == "combined")
            }
            completion?(.success(Data(response.utf8)))
            if state == "missing-provider" { precondition(panel.feed == nil && !panel.isFresh) }
            if state == "empty-feed" { precondition(panel.feed?.tabs.isEmpty == true && panel.isFresh) }
            panel.selectTab(state == "todo" ? "todo" : "work")
            panel.setDraft("Make the example setup easier to follow.", tabID: "todo", actionID: "add")
            if state == "combined" {
                panel.setDraft("  Keep this combined-tab draft 👋\n", tabID: "work", actionID: "add")
                precondition(panel.selectedTab?.form != nil && panel.selectedTab?.validTrack?.stages.count == 24)
            }
            if state == "confirmation" {
                panel.preview(actionID: "review"); completion?(.success(Data(authority.utf8)))
            }
            if state == "unavailable" {
                panel.refresh()
                completion?(.success(Data(#"{"status":200,"data":{"available":false,"reason":"Fictional provider is offline."}}"#.utf8)))
            }
            if state == "unknown" {
                panel.preview(actionID: "review"); completion?(.success(Data(authority.utf8)))
                panel.sendPreview()
                completion?(.success(Data(#"{"status":504,"data":{"ok":false}}"#.utf8)))
                panel.refresh(); completion?(.success(Data(feed.utf8)))
            }
            if state == "settings-off" { panel.setEnabled(false) }
            for dark in [false, true] {
                for size in [NSSize(width: 960, height: 620), NSSize(width: 1120, height: 750), NSSize(width: 1440, height: 900)] {
                    if state == "combined" { panel.selectedItemKey = "work/0/0" }
                    let content: AnyView
                    if state == "settings-off" {
                        content = AnyView(PanelSettingsView(panel: panel).frame(width: 500).padding(28)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Palette.surface))
                    } else if state == "confirmation", let confirmation = panel.confirmation {
                        content = AnyView(PanelConfirmationView(panel: panel, confirmation: confirmation)
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.background))
                    } else {
                        content = AnyView(WorkOverview(store: store))
                    }
                    let host = NSHostingView(rootView: content.foregroundStyle(Palette.ink).tint(Palette.accent)
                        .environment(\.controlActiveState, .active)
                        .environment(\.colorScheme, dark ? .dark : .light))
                    host.sizingOptions = []
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = NSRect(origin: .zero, size: size)
                    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.contentView = host
                    for _ in 0..<4 { host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
                    precondition(!window.isVisible && !window.isKeyWindow, "Captures must remain offscreen")
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(state)-\(dark ? "dark" : "light")-\(Int(size.width))x\(Int(size.height)).png"))
                    if state == "combined" {
                        panel.selectedItemKey = "work/0/1"
                        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
                        let selected = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                        host.cacheDisplay(in: host.bounds, to: selected)
                        let file = output.appendingPathComponent("combined-after-selection-\(dark ? "dark" : "light")-\(Int(size.width))x\(Int(size.height)).png")
                        try selected.representation(using: .png, properties: [:])!.write(to: file)
                        let recognition = VNRecognizeTextRequest()
                        try VNImageRequestHandler(cgImage: selected.cgImage!, options: [:]).perform([recognition])
                        let columnBoundary = (232 + 22 + 320 + 20) / size.width
                        let right = (recognition.results ?? []).filter { $0.boundingBox.minX > columnBoundary }
                            .compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                        precondition(right.contains("Make setup easier"), "Combined form+track must keep selected lower-stage details visible: \(file.path)\n\(right)")
                        let stage = (recognition.results ?? []).filter { $0.boundingBox.minX > 232 / size.width && $0.boundingBox.minX < columnBoundary }
                            .compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                        precondition(stage.contains("Example stage 24"), "Selected lower stage must remain in its own scroll pane")
                        precondition(panel.draft(tabID: "work", actionID: "add") == "  Keep this combined-tab draft 👋\n")
                    }
                    window.contentView = nil; window.close()
                }
            }
            panel.cancelPreview()
        }
        print("Combined form + 24 stages: selected detail, independent stage position and exact draft verified at all six sizes/appearances")
        print("Offscreen fictional panel captures: \(output.path)")
    }
}
