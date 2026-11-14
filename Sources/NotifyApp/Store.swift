import Foundation
import Combine
import NotifyCore

struct AuditEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let session: String
    let action: String
    let automatic: Bool
}

struct AnswerFocus: Equatable {
    let id = UUID()
    let requestID: String
    let questionID: String
}

enum AppearanceMode: String, CaseIterable {
    case system, light, dark
}

final class Store: ObservableObject {
    @Published private(set) var registry = SessionRegistry()
    @Published var selectedID: String?
    @Published var selectedRequestID: String?
    private(set) var selectionIsExplicit = false
    @Published var waitingOnly = false
    @Published private(set) var sessionOrder: [String]
    @Published var error: String?
    @Published var requestErrors: [String: String] = [:]
    @Published var sessionErrors: [String: String] = [:]
    @Published private(set) var appearance = SessionAppearance()
    var attentionIDs = Set<String>()
    private var announcedIDs: [String] = []
    private var replyAttempts: [String: UUID] = [:]
    @Published var settingsVisible = false
    @Published var appearanceMode: AppearanceMode {
        didSet { defaults.set(appearanceMode.rawValue, forKey: "appearanceMode") }
    }
    @Published var centerVisible = false
    @Published var floatingColorPickerSessionID: String? {
        didSet { onAttentionChange?() }
    }
    @Published var editingReplyText = false
    @Published var answerFocus: AnswerFocus?
    @Published var floatingExpanded = false {
        didSet { onAttentionChange?() }
    }
    @Published var sending = Set<String>()
    @Published var automaticallySending = Set<String>()
    @Published var mutedSessions = Set<String>()
    @Published var audit: [AuditEntry] = []
    @Published var replyWorkspace = ReplyWorkspace()
    @Published var steeringWorkspace = SteeringWorkspace()
    @Published private(set) var automation = SessionAutomation()
    @Published var steeringSessionID: String?
    @Published private(set) var terminalBusy = Set<String>()
    @Published private(set) var launching = Set<String>()
    private var terminalTasks: [String: Task<Void, Never>] = [:]
    @Published private(set) var descriptions: [String: SessionDescription] = [:]
    @Published private(set) var summarizingID: String?
    @Published var autoYes: Bool {
        didSet { defaults.set(autoYes, forKey: "autoYes") }
    }
    @Published var floatingEnabled: Bool {
        didSet { defaults.set(floatingEnabled, forKey: "floatingEnabled"); onAttentionChange?() }
    }
    @Published var playSound: Bool {
        didSet { defaults.set(playSound, forKey: "playSound") }
    }
    var onAttentionChange: (() -> Void)?
    let directory: URL
    let server: LocalServer
    private let defaults: UserDefaults
    private var snoozed = Set<String>()
    private var discoveryTimer: DispatchSourceTimer?
    private var lastDiscoveryError: String?
    private let descriptionRunner = DescriptionRunner()

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedAppearance = defaults.string(forKey: "appearanceMode")
        appearanceMode = savedAppearance.flatMap(AppearanceMode.init(rawValue:)) ?? .system
        sessionOrder = defaults.stringArray(forKey: "sessionOrder") ?? []
        defaults.register(defaults: ["autoYes": true, "floatingEnabled": true, "playSound": false])
        autoYes = defaults.bool(forKey: "autoYes")
        floatingEnabled = defaults.bool(forKey: "floatingEnabled")
        playSound = defaults.bool(forKey: "playSound")
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Notify")
        server = LocalServer(directory: self.directory)
        if let savedAppearance, AppearanceMode(rawValue: savedAppearance) == nil {
            error = "The saved appearance setting is not recognized. Notify is following the system; choose an appearance in Settings to reset it."
        }
        do { appearance = try SessionAppearance.load(from: self.directory) }
        catch { self.error = "Session colors could not be loaded: \(error.localizedDescription)" }
        do { descriptions = try DescriptionCache.load(from: self.directory) }
        catch { self.error = "Saved descriptions could not be read: \(error.localizedDescription)" }
        let auditPath = self.directory.appendingPathComponent("history.json")
        if FileManager.default.fileExists(atPath: auditPath.path) {
            do { audit = try JSONDecoder().decode([AuditEntry].self, from: Data(contentsOf: auditPath)) }
            catch { self.error = "Approval history could not be read: \(error.localizedDescription)" }
        }
        server.onPacket = { [weak self] packet in self?.receive(packet) }
        server.onError = { [weak self] error in self?.error = error }
        server.onDisconnect = { [weak self] id in
            guard let self else { return }
            for request in self.registry.sessions[id]?.requests ?? [] {
                self.sending.remove(request.id)
                self.automaticallySending.remove(request.id)
            }
            self.disableSessionAutoYes(id, reason: "connection closed")
            self.steeringWorkspace.disconnect(id)
            self.registry.disconnect(id)
            self.onAttentionChange?()
        }
    }
    var sessions: [SessionRecord] {
        registry.sessions.values.sorted {
            if ($0.state == "waiting") != ($1.state == "waiting") { return $0.state == "waiting" }
            return $0.updated > $1.updated
        }
    }
    var selected: SessionRecord? { selectedID.flatMap { registry.sessions[$0] } }
    func setColor(_ value: UInt32?, for session: SessionRecord) {
        do { try appearance.set(value, for: session, in: directory) }
        catch { self.error = "Session color could not be saved: \(error.localizedDescription)" }
    }
    func rememberSessionOrder(_ ids: [String]) {
        guard ids.allSatisfy({ registry.sessions[$0] != nil }) else {
            error = "Session order could not be saved because a session is no longer available."
            return
        }
        var seen = Set<String>()
        let keys = ids.compactMap { registry.sessions[$0] }.map { $0.sourceSessionID ?? $0.id }
            .filter { seen.insert($0).inserted }
        sessionOrder = keys + sessionOrder.filter { seen.insert($0).inserted }
        defaults.set(sessionOrder, forKey: "sessionOrder")
    }
    func openTerminal(_ session: SessionRecord, resume: Bool = false) {
        guard !terminalBusy.contains(session.id), !launching.contains(session.id) else { return }
        guard session.agent == "copilot" else {
            sessionErrors[session.id] = "Exact terminal navigation is currently available for discovered Copilot sessions."
            return
        }
        terminalBusy.insert(session.id)
        sessionErrors.removeValue(forKey: session.id)
        let rowID = session.id
        let sourceID = session.sourceSessionID ?? session.id
        terminalTasks[session.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.terminalBusy.remove(session.id); self.terminalTasks.removeValue(forKey: session.id) }
            do {
                let live = try await Task.detached {
                    try CopilotDiscovery.sessions(in: TerminalSession.copilotHome.appendingPathComponent("session-state"),
                                                 livePIDs: CopilotDiscovery.runningPIDs())
                }.value
                if let owner = live.first(where: { $0.id == sourceID }) {
                    try await TerminalSession.focus(pid: owner.pid)
                } else if resume && session.isSaved {
                    try await TerminalSession.resume(id: sourceID, cwd: session.cwd)
                    self.launching.insert(session.id)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                        guard let self, self.launching.remove(rowID) != nil else { return }
                        self.sessionErrors[rowID] = "iTerm2 opened, but no live owner was detected yet. Check that terminal before launching again."
                    }
                } else {
                    self.sessionErrors[session.id] = "This chat has no identifiable live Copilot terminal. Refresh the saved session list before resuming."
                }
            } catch { self.sessionErrors[session.id] = error.localizedDescription }
        }
    }
    func showSteering(_ id: String?) {
        steeringSessionID = id ?? selectedID ?? sessions.first(where: { $0.connected && $0.canSteer })?.id ?? sessions.first?.id
        onAttentionChange?()
    }
    func closeSteering() { steeringSessionID = nil; onAttentionChange?() }
    func steer(_ id: String, action: String) {
        guard let session = registry.sessions[id] else { error = "This session is no longer available."; return }
        do {
            if action == "stop" { disableSessionAutoYes(id, reason: "Stop requested") }
            let commandID = try steeringWorkspace.begin(session: session, action: action)
            do {
                try server.send(sessionID: id, message: ["type": "control", "commandID": commandID, "action": action,
                    "text": steeringWorkspace.receipts[id]?.message ?? ""])
            } catch {
                steeringWorkspace.update(sessionID: id, commandID: commandID, status: "failed", text: "Could not dispatch: \(error.localizedDescription)")
                throw error
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.steeringWorkspace.receipts[id]?.id == commandID,
                      self.steeringWorkspace.receipts[id]?.status == "sending" else { return }
                self.steeringWorkspace.update(sessionID: id, commandID: commandID, status: "unknown",
                    text: "No acknowledgment yet. Check the session before resending; the message may have arrived.")
                self.disableSessionAutoYes(id, reason: "steering acknowledgment timed out")
            }
        } catch {
            disableSessionAutoYes(id, reason: "steering dispatch failed")
            self.error = "Could not send control: \(error.localizedDescription)"
        }
    }
    func setSessionAutoYes(_ id: String, enabled: Bool) {
        guard let session = registry.sessions[id] else { error = "This session is no longer available."; return }
        if !enabled { automation.disable(id) }
        do {
            var next = automation
            try next.setEnabled(enabled, for: session)
            try record(session: session, action: enabled ? "Enabled session Auto-yes (not recommended)" : "Disabled session Auto-yes", automatic: false)
            automation = next
        } catch { self.error = "Could not change Auto-yes: \(error.localizedDescription)" }
    }
    private func disableSessionAutoYes(_ id: String, reason: String) {
        guard automation.enabled.contains(id) else { return }
        automation.disable(id)
        if let session = registry.sessions[id] {
            do { try record(session: session, action: "Disabled session Auto-yes: \(reason)", automatic: false) }
            catch { self.error = "Auto-yes is off, but its audit entry could not be saved: \(error.localizedDescription)" }
        }
    }
    func description(for session: SessionRecord) -> SessionDescription? {
        descriptions[session.sourceSessionID ?? session.id]
    }
    func summarize(_ session: SessionRecord) {
        guard summarizingID == nil, session.agent == "copilot" else { return }
        guard let resources = Bundle.main.resourceURL else { error = "Notify's installed resources are missing."; return }
        let script = resources.appendingPathComponent("bridge/dist/summarize.js")
        guard FileManager.default.fileExists(atPath: script.path) else { error = "The summary helper is missing. Reinstall Notify."; return }
        let id = session.sourceSessionID ?? session.id
        do {
            try descriptionRunner.run(sessionID: id, script: script) { [weak self] result in
                guard let self else { return }
                self.summarizingID = nil
                switch result {
                case .success(let description):
                    var next = self.descriptions
                    next[id] = description
                    do {
                        try DescriptionCache.save(next, in: self.directory)
                        self.descriptions = next
                    } catch { self.error = "Description could not be saved: \(error.localizedDescription)" }
                case .failure(let error): self.error = "Could not summarize: \(error.localizedDescription)"
                }
            }
            summarizingID = session.id
        } catch { self.error = "Could not start summary: \(error.localizedDescription)" }
    }
    func stop() {
        for id in Array(automation.enabled) { disableSessionAutoYes(id, reason: "app closing") }
        discoveryTimer?.cancel(); descriptionRunner.cancel(); server.stop()
    }
    var activeRequest: AgentRequest? {
        guard let selected else { return nil }
        return selected.requests.first(where: { $0.id == selectedRequestID }) ?? selected.requests.first
    }
    var pending: [(session: SessionRecord, request: AgentRequest)] {
        sessions.filter(\.connected).flatMap { session in session.requests.map { (session, $0) } }
    }
    var waitingCount: Int {
        pending.filter { !automaticallySending.contains($0.request.id) }.count
    }
    var floatingRequests: [(session: SessionRecord, request: AgentRequest)] {
        pending.filter { !snoozed.contains($0.request.id) && !automaticallySending.contains($0.request.id) }
    }
    func start() {
        do { try server.start() }
        catch { self.error = "Could not start local listener: \(error.localizedDescription)" }
        let home = ProcessInfo.processInfo.environment["COPILOT_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot")
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "notify.discovery", qos: .utility))
        timer.schedule(deadline: .now(), repeating: 30)
        timer.setEventHandler { [weak self] in
            do {
                let found = try CopilotDiscovery.catalog(in: home.appendingPathComponent("session-state"),
                    livePIDs: CopilotDiscovery.runningPIDs())
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.registry.catalog(found)
                    for item in found where item.pid != nil {
                        for row in self.sessions where (row.sourceSessionID ?? row.id) == item.id { self.launching.remove(row.id) }
                    }
                    let metadataError = found.compactMap(\.metadataError).first
                    if let metadataError, metadataError != self.lastDiscoveryError { self.error = metadataError }
                    self.lastDiscoveryError = metadataError
                    if self.selectedID == nil { self.selectedID = self.sessions.first?.id }
                }
            } catch {
                DispatchQueue.main.async { self?.error = "Copilot discovery failed: \(error.localizedDescription)" }
            }
        }
        discoveryTimer = timer
        timer.resume()
    }
    func select(_ id: String, request: String? = nil) {
        selectionIsExplicit = true
        selectedRequestID = request
        selectedID = id
    }
    func reconcileSelection(in visible: [SessionRecord]) {
        if selectionIsExplicit, visible.contains(where: { $0.id == selectedID }) { return }
        let preferred = visible.first { $0.connected && !$0.requests.isEmpty }
            ?? visible.first { $0.connected && !$0.needsSetup } ?? visible.first
        selectionIsExplicit = false
        if selectedID != preferred?.id {
            selectedRequestID = nil
            selectedID = preferred?.id
        }
    }
    var activeFloatingRequest: (session: SessionRecord, request: AgentRequest)? {
        let requests = floatingRequests
        return requests.first { $0.request.id == replyWorkspace.floatingID } ?? requests.first
    }
    func activateReplyChoice() -> String? {
        guard let item = activeFloatingRequest, item.session.connected, !sending.contains(item.request.id) else { return nil }
        let request = item.request
        let draft = replyWorkspace.drafts[request.id] ?? ReplyDraft()
        switch replyWorkspace.choice(for: request) {
        case .allowOnce:
            reply(session: item.session.id, request: request, decision: "allow")
        case .scope(let id):
            reply(session: item.session.id, request: request, decision: "allow", permissionOptionID: id)
        case .deny:
            let feedback = draft.feedback.trimmingCharacters(in: .whitespacesAndNewlines)
            reply(session: item.session.id, request: request, decision: "deny", feedback: feedback.isEmpty ? nil : feedback)
        case .send:
            let answers = draft.answers(for: request)
            guard request.accepts(decision: "answer", answers: answers) else {
                requestErrors[request.id] = "Choose an answer for each required question before sending."
                return nil
            }
            reply(session: item.session.id, request: request, decision: "answer", answers: answers)
        case .option(let id, let label):
            guard let question = request.questions.first(where: { $0.id == id }) else { return nil }
            replyWorkspace.toggleOption(label, question: question, request: request)
        case .input(let id):
            return id
        }
        return nil
    }
    func snooze(_ id: String) {
        snoozed.insert(id)
        onAttentionChange?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            self?.snoozed.remove(id)
            self?.attentionIDs.insert(id)
            self?.onAttentionChange?()
        }
    }
    func clearDisconnected() {
        for session in sessions where !session.connected && !session.needsSetup {
            for request in session.requests { replyWorkspace.resolve(request.id) }
            registry.remove(session.id)
        }
    }
    private func receive(_ packet: AgentPacket) {
        switch packet.type {
        case "hello":
            disableSessionAutoYes(packet.sessionID, reason: "connection reinitialized")
            steeringWorkspace.disconnect(packet.sessionID)
            sending.subtract(registry.sessions[packet.sessionID]?.requests.map(\.id) ?? [])
            automaticallySending.subtract(registry.sessions[packet.sessionID]?.requests.map(\.id) ?? [])
            registry.register(id: packet.sessionID, agent: packet.agent ?? "", cwd: packet.cwd ?? "")
            if selectedID == nil { selectedID = packet.sessionID }
        case "state":
            registry.state(packet.sessionID, state: packet.state ?? "", text: packet.text ?? "")
        case "metadata":
            let aliases = registry.sessions.values.filter {
                !$0.connected && ($0.id == packet.sourceSessionID || $0.sourceSessionID == packet.sourceSessionID && packet.sourceSessionID != nil)
            }.map(\.id)
            if let title = packet.title { registry.title(packet.sessionID, text: title, sourceSessionID: packet.sourceSessionID) }
            for alias in aliases where registry.sessions[alias] == nil {
                if selectedID == alias { selectedID = packet.sessionID }
                if steeringSessionID == alias { steeringSessionID = packet.sessionID }
            }
        case "capabilities":
            registry.capabilities(packet.sessionID, steering: packet.steering == true, autoYes: packet.sessionAutoYes == true)
            registry.activityCapability(packet.sessionID, enabled: packet.activityFeed == true)
            if packet.sessionAutoYes != true { disableSessionAutoYes(packet.sessionID, reason: "capability unavailable") }
        case "activity":
            guard let activity = packet.activity else { sessionErrors[packet.sessionID] = "Agent sent an empty activity event."; return }
            do {
                let previous = registry.sessions[packet.sessionID]?.activity.entries.first(where: { $0.id == activity.id })
                try registry.activity(packet.sessionID, entry: activity)
                if activity.kind == "assistant", activity.status == "complete", previous?.status != "complete" {
                    registry.output(packet.sessionID, text: activity.detail + "\n\n")
                }
            }
            catch { sessionErrors[packet.sessionID] = "Invalid activity event; check the original terminal." }
        case "control_status":
            if let id = packet.commandID, let status = packet.status {
                steeringWorkspace.update(sessionID: packet.sessionID, commandID: id, status: status, text: packet.text ?? "")
                if ["failed", "unknown"].contains(status) { disableSessionAutoYes(packet.sessionID, reason: "steering delivery failed or uncertain") }
            }
        case "output":
            registry.output(packet.sessionID, text: packet.text ?? "")
        case "request":
            guard let request = packet.request else { error = "Launcher sent an empty request."; return }
            let alreadyPresent = registry.sessions[packet.sessionID]?.requests.contains { $0.id == request.id } == true
            do { try registry.add(request, to: packet.sessionID) }
            catch { self.error = "Invalid or excessive pending requests."; return }
            if !announcedIDs.contains(request.id) {
                announcedIDs.append(request.id)
                if announcedIDs.count > 1000 { announcedIDs.removeFirst() }
                attentionIDs.insert(request.id)
            }
            if !alreadyPresent, let session = registry.sessions[packet.sessionID],
               let scope = automation.scope(for: request, session: session, safeEnabled: autoYes, muted: mutedSessions.contains(packet.sessionID)) {
                reply(session: packet.sessionID, request: request, decision: "allow", automatic: true, approvalScope: scope)
            }
        // Older bridges echoed the incoming reply type after runtime acknowledgment.
        case "resolved", "reply":
            guard let id = packet.requestID else { return }
            let wasAutomatic = packet.automatic == true
            if let session = registry.sessions[packet.sessionID],
               session.requests.contains(where: { $0.id == id }), !wasAutomatic, packet.cancelled != true {
                let option = session.requests.first(where: { $0.id == id })?.permissionOptions?.first(where: { $0.id == packet.permissionOptionID })
                do { try record(session: session, action: option.map { "Reply acknowledged: \($0.label) - \($0.detail)" } ?? packet.decision ?? "answered", automatic: false) }
                catch { self.error = "Reply delivered, but approval history could not be saved: \(error.localizedDescription)" }
            }
            registry.resolve(sessionID: packet.sessionID, requestID: id)
            replyWorkspace.resolve(id)
            sending.remove(id)
            automaticallySending.remove(id)
            snoozed.remove(id)
            requestErrors.removeValue(forKey: id)
            replyAttempts.removeValue(forKey: id)
            attentionIDs.remove(id)
        case "error":
            disableSessionAutoYes(packet.sessionID, reason: "agent reported an error")
            if let id = packet.requestID, registry.sessions[packet.sessionID]?.requests.contains(where: { $0.id == id }) == true {
                requestErrors[id] = packet.text ?? "Reply failed. Check the terminal before retrying."
                sending.remove(id)
                automaticallySending.remove(id)
            } else {
                sessionErrors[packet.sessionID] = packet.text ?? "Agent reported an error."
                sending.subtract(registry.sessions[packet.sessionID]?.requests.map(\.id) ?? [])
                automaticallySending.subtract(registry.sessions[packet.sessionID]?.requests.map(\.id) ?? [])
            }
        default: error = "Unsupported launcher event: \(packet.type)"
        }
        onAttentionChange?()
    }
    private func record(session: SessionRecord, action: String, automatic: Bool) throws {
        let entry = AuditEntry(id: UUID(), date: Date(), session: "\(session.agent) / \(session.name) / \(session.id.prefix(8))", action: action, automatic: automatic)
        let next = Array(([entry] + audit).prefix(200))
        let path = directory.appendingPathComponent("history.json")
        try JSONEncoder().encode(next).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        audit = next
    }
    func reply(session id: String, request: AgentRequest, decision: String, answers: [String: [String]] = [:], automatic: Bool = false, approvalScope: String? = nil, permissionOptionID: String? = nil, feedback: String? = nil) {
        guard !sending.contains(request.id),
              registry.canReply(sessionID: id, requestID: request.id, decision: decision, answers: answers, permissionOptionID: permissionOptionID, feedback: feedback),
              !(automatic && (permissionOptionID != nil || feedback != nil)),
              let session = registry.sessions[id] else { error = "This request is no longer available, or its answer is incomplete."; return }
        do {
            if let permissionOptionID,
               let option = session.requests.first(where: { $0.id == request.id })?.permissionOptions?.first(where: { $0.id == permissionOptionID }) {
                try record(session: session, action: "Requested: \(option.label) - \(option.detail)", automatic: false)
            }
            if automatic {
                guard let current = session.requests.first(where: { $0.id == request.id }),
                      let scope = automation.scope(for: current, session: session, safeEnabled: autoYes, muted: mutedSessions.contains(id)),
                      scope == approvalScope, decision == "allow" else { throw ProtocolError.invalid }
                try record(session: session, action: scope == "session" ? "Session Auto-yes: permission approval dispatched" : "Allow once: verified in-project source read (dispatched)", automatic: true)
            }
            sending.insert(request.id)
            if automatic { automaticallySending.insert(request.id) }
            let attempt = UUID()
            replyAttempts[request.id] = attempt
            requestErrors.removeValue(forKey: request.id)
            var message: [String: Any] = ["type": "reply", "requestID": request.id,
                "decision": decision, "answers": answers, "automatic": automatic]
            if automatic, let approvalScope { message["approvalScope"] = approvalScope }
            if let permissionOptionID { message["permissionOptionID"] = permissionOptionID }
            if let feedback { message["feedback"] = feedback }
            try server.send(sessionID: id, message: message)
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, self.sending.contains(request.id), self.replyAttempts[request.id] == attempt else { return }
                self.sending.remove(request.id)
                self.automaticallySending.remove(request.id)
                self.disableSessionAutoYes(id, reason: "reply acknowledgment timed out")
                self.requestErrors[request.id] = "No acknowledgment yet. The reply may have arrived; check the terminal before retrying."
                self.onAttentionChange?()
            }
            onAttentionChange?()
        } catch {
            if automatic { disableSessionAutoYes(id, reason: "approval dispatch failed") }
            sending.remove(request.id)
            automaticallySending.remove(request.id)
            self.requestErrors[request.id] = "No approval sent: \(error.localizedDescription)"
        }
    }
}
