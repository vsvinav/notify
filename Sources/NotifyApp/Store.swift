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
    @Published private(set) var registry = SessionRegistry() {
        didSet { mobile.workspaceChanged() }
    }
    @Published var selectedID: String?
    @Published var selectedRequestID: String?
    private(set) var selectionIsExplicit = false
    @Published var waitingOnly = false
    @Published private(set) var sessionOrder: [String]
    @Published var error: String?
    @Published var requestErrors: [String: String] = [:]
    @Published private var localSessionErrors: [String: String] = [:]
    @Published private var agentErrors: [String: String] = [:]
    var sessionErrors: [String: String] {
        agentErrors.merging(localSessionErrors) { _, local in local }
    }
    @Published private(set) var appearance = SessionAppearance() {
        didSet { mobile.workspaceChanged() }
    }
    var attentionIDs = Set<String>()
    private var announcedIDs: [String] = []
    private var replyAttempts: [String: UUID] = [:]
    @Published var settingsVisible = false
    @Published var setupVisible = false {
        didSet { onAttentionChange?() }
    }
    @Published var setupAgent = SetupAgent.copilot
    @Published var setupSnapshot: AgentSetupSnapshot?
    @Published var setupError: String?
    @Published var copilotSetupError: String?
    @Published private(set) var setupBusy = false
    @Published private(set) var setupInstalled = false
    private var welcomePending: Bool
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
    @Published var steeringWorkspace = SteeringWorkspace() {
        didSet { mobile.workspaceChanged() }
    }
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
    let mobile: MobileConnection
    private var mobileReplies: [String: MobileReply] = [:]
    private var phoneWorkspace = MobileWorkspace()
    private var phoneControls: [String: MobileControl] = [:]
    private let defaults: UserDefaults
    private var snoozed = Set<String>()
    private var discoveryTimer: DispatchSourceTimer?
    private var lastDiscoveryError: String?
    private let descriptionRunner = DescriptionRunner()

    init(directory: URL? = nil, defaults: UserDefaults = .standard, mobileResources: URL? = Bundle.main.resourceURL) {
        self.defaults = defaults
        let savedAppearance = defaults.string(forKey: "appearanceMode")
        appearanceMode = savedAppearance.flatMap(AppearanceMode.init(rawValue:)) ?? .system
        sessionOrder = defaults.stringArray(forKey: "sessionOrder") ?? []
        defaults.register(defaults: ["autoYes": true, "floatingEnabled": true, "playSound": false])
        autoYes = defaults.bool(forKey: "autoYes")
        floatingEnabled = defaults.bool(forKey: "floatingEnabled")
        playSound = defaults.bool(forKey: "playSound")
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Notify")
        let seenWelcome = defaults.object(forKey: "hasSeenWelcome") as? Bool
        welcomePending = seenWelcome == false || (seenWelcome == nil && !FileManager.default.fileExists(atPath: self.directory.path))
        if welcomePending && seenWelcome == nil { defaults.set(false, forKey: "hasSeenWelcome") }
        server = LocalServer(directory: self.directory)
        mobile = MobileConnection(directory: self.directory.appendingPathComponent("mobile"), defaults: defaults, resources: mobileResources)
        mobile.snapshot = { [weak self] in self?.phoneSnapshot() ?? [] }
        mobile.onReply = { [weak self] reply in self?.replyFromPhone(reply) }
        mobile.workspaceSnapshot = { [weak self] ids in try self?.phoneWorkspaceSnapshot(watching: ids) ?? [] }
        mobile.onControl = { [weak self] control in self?.controlFromPhone(control) }
        mobile.onUnavailable = { [weak self] in
            guard let self else { return }
            self.mobileReplies.removeAll()
            for (commandID, control) in self.phoneControls {
                self.steeringWorkspace.update(sessionID: control.sessionID, commandID: commandID, status: "unknown", text: "Phone connection unavailable. Check the session before retrying.")
            }
            self.phoneControls.removeAll()
            self.phoneWorkspace.invalidate()
        }
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
                self.finishPhoneReply(request.id, sessionID: id, error: "The agent disconnected. Check the Mac before retrying.")
                self.sending.remove(request.id)
                self.automaticallySending.remove(request.id)
            }
            self.disableSessionAutoYes(id, reason: "connection closed")
            self.steeringWorkspace.disconnect(id)
            self.registry.disconnect(id)
            self.expirePhoneControls()
            self.mobile.publish()
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
    func offerWelcome() {
        guard welcomePending else { return }
        welcomePending = false
        defaults.set(true, forKey: "hasSeenWelcome")
        if !sessions.contains(where: \.connected) { showSetup() }
    }
    func showSetup(_ agent: SetupAgent? = nil) {
        welcomePending = false
        defaults.set(true, forKey: "hasSeenWelcome")
        if let agent { setupAgent = agent }
        settingsVisible = false
        setupVisible = true
    }
    func setupConnectionCount(_ agent: SetupAgent) -> Int {
        sessions.filter { $0.agent == agent.rawValue && $0.connected && !$0.needsSetup && !$0.isSaved }.count
    }
    func refreshSetup() {
        guard !setupBusy else { return }
        setupBusy = true
        setupError = nil
        setupInstalled = false
        setupSnapshot = nil
        let resources = Bundle.main.resourceURL
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.setupBusy = false }
            do { self.setupSnapshot = try await Task.detached { try AgentSetup.inspect(resources: resources) }.value }
            catch { self.setupError = "Could not check agent setup: \(AgentSetup.failureDescription(error))" }
        }
    }
    func installCopilotExtension() {
        guard !setupBusy, let snapshot = setupSnapshot else { return }
        setupBusy = true
        setupInstalled = false
        copilotSetupError = nil
        let resources = Bundle.main.resourceURL
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.setupBusy = false }
            do {
                self.setupSnapshot = try await Task.detached {
                    try AgentSetup.installCopilot(snapshot)
                    return try AgentSetup.inspect(resources: resources, path: snapshot.searchPath, copilotHome: snapshot.copilotHome)
                }.value
                self.setupInstalled = true
            } catch { self.copilotSetupError = "Copilot extension setup did not finish: \(AgentSetup.failureDescription(error))" }
        }
    }
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
            localSessionErrors[session.id] = "Exact terminal navigation is currently available for discovered Copilot sessions."
            return
        }
        terminalBusy.insert(session.id)
        localSessionErrors.removeValue(forKey: session.id)
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
                        self.localSessionErrors[rowID] = "iTerm2 opened, but no live owner was detected yet. Check that terminal before launching again."
                    }
                } else {
                    self.localSessionErrors[session.id] = "This chat has no identifiable live Copilot terminal. Refresh the saved session list before resuming."
                }
            } catch { self.localSessionErrors[session.id] = error.localizedDescription }
        }
    }
    func showSteering(_ id: String?) {
        steeringSessionID = id ?? selectedID ?? sessions.first(where: { $0.connected && $0.canSteer })?.id ?? sessions.first?.id
        onAttentionChange?()
    }
    func closeSteering() { steeringSessionID = nil; onAttentionChange?() }
    @discardableResult
    func steer(_ id: String, action: String, agentID: String? = nil, creation: SubagentCreation? = nil, phoneText: String? = nil) -> String? {
        guard let session = registry.sessions[id] else { error = "This session is no longer available."; return nil }
        do {
            if action == "stop", agentID == nil { disableSessionAutoYes(id, reason: "Stop requested") }
            let commandID = try steeringWorkspace.begin(session: session, action: action, agentID: agentID, creation: creation, phoneText: phoneText)
            do {
                if let creation {
                    try record(session: session, action: "Requested subagent creation: \(creation.name) (\(creation.agentType))", automatic: false)
                } else if action == "remove_subagent", let agentID {
                    try record(session: session, action: "Requested removal of ended subagent: \(agentID)", automatic: false)
                }
                var message: [String: Any] = ["type": "control", "commandID": commandID, "action": action,
                    "text": steeringWorkspace.receipt(sessionID: id, commandID: commandID)?.message ?? ""]
                if let agentID { message["agentID"] = agentID }
                if let creation {
                    message["agentName"] = creation.name
                    message["agentType"] = creation.agentType
                    if let model = creation.model { message["model"] = model }
                }
                try server.send(sessionID: id, message: message)
            } catch {
                steeringWorkspace.update(sessionID: id, commandID: commandID, status: "failed", text: "Could not dispatch: \(error.localizedDescription)")
                throw error
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.steeringWorkspace.receipt(sessionID: id, commandID: commandID)?.status == "sending" else { return }
                self.steeringWorkspace.update(sessionID: id, commandID: commandID, status: "unknown",
                    text: "No acknowledgment yet. Check the session before retrying; the action may already have happened.")
                self.disableSessionAutoYes(id, reason: "steering acknowledgment timed out")
                self.finishPhoneControl(commandID, status: "unknown", detail: "No runtime acknowledgment. Check the session before retrying.", error: "Delivery is uncertain.")
            }
            return commandID
        } catch {
            disableSessionAutoYes(id, reason: "steering dispatch failed")
            self.error = "Could not send control: \(error.localizedDescription)"
            return nil
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
        guard automation.activeIDs.contains(id) else { return }
        let mode = automation.dangerous.contains(id) ? "Dangerous Auto-yes" : "session Auto-yes"
        automation.disable(id)
        if let session = registry.sessions[id] {
            do { try record(session: session, action: "Disabled \(mode): \(reason)", automatic: false) }
            catch { self.error = "Auto-yes is off, but its audit entry could not be saved: \(error.localizedDescription)" }
        }
    }
    func setSessionDangerousAutoYes(_ id: String, enabled: Bool) {
        guard let session = registry.sessions[id] else { error = "This session is no longer available."; return }
        if !enabled { automation.disable(id) }
        do {
            var next = automation
            try next.setDangerousEnabled(enabled, for: session)
            try record(session: session, action: enabled ? "Enabled Dangerous Auto-yes, including waiting eligible tools" : "Disabled Dangerous Auto-yes", automatic: false)
            automation = next
            if enabled {
                for request in session.requests where !sending.contains(request.id) {
                    guard automation.dangerous.contains(id) else { break }
                    if automation.scope(for: request, session: session, safeEnabled: false, muted: false) == "session" {
                        reply(session: id, request: request, decision: "allow", automatic: true, approvalScope: "session")
                    }
                }
            }
        } catch {
            self.error = enabled ? "Could not enable Dangerous Auto-yes: \(error.localizedDescription)" :
                "Dangerous Auto-yes is off, but its audit entry could not be saved: \(error.localizedDescription)"
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
        mobile.stop()
        for id in automation.activeIDs { disableSessionAutoYes(id, reason: "app closing") }
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
        mobile.start()
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
            agentErrors.removeValue(forKey: session.id)
            localSessionErrors.removeValue(forKey: session.id)
        }
    }
    private func receive(_ packet: AgentPacket) {
        switch packet.type {
        case "hello":
            for request in registry.sessions[packet.sessionID]?.requests ?? [] {
                finishPhoneReply(request.id, sessionID: packet.sessionID, error: "The agent reconnected. Refresh the request before replying.")
            }
            disableSessionAutoYes(packet.sessionID, reason: "connection reinitialized")
            steeringWorkspace.disconnect(packet.sessionID)
            sending.subtract(registry.sessions[packet.sessionID]?.requests.map(\.id) ?? [])
            automaticallySending.subtract(registry.sessions[packet.sessionID]?.requests.map(\.id) ?? [])
            registry.register(id: packet.sessionID, agent: packet.agent ?? "", cwd: packet.cwd ?? "")
            if selectedID == nil { selectedID = packet.sessionID }
        case "state":
            registry.state(packet.sessionID, state: packet.state ?? "", text: packet.text ?? "")
            if packet.state == "working" { registry.resumeWork(packet.sessionID) }
            // Idle can follow a failed turn; retire its error only when work resumes.
            if packet.state == "working", agentErrors[packet.sessionID] != nil {
                agentErrors.removeValue(forKey: packet.sessionID)
            }
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
            registry.capabilities(packet.sessionID, steering: packet.steering == true, autoYes: packet.sessionAutoYes == true,
                                  subagentChat: packet.subagentChat == true, subagentStop: packet.subagentStop == true)
            if registry.sessions[packet.sessionID]?.agent == "copilot" {
                do {
                    try registry.managementCapabilities(packet.sessionID, create: packet.subagentCreate == true,
                        remove: packet.subagentRemove == true, types: packet.subagentTypes ?? [], models: packet.subagentModels ?? [])
                } catch { localSessionErrors[packet.sessionID] = "Invalid subagent management capabilities; reload the extension." }
            }
            registry.activityCapability(packet.sessionID, enabled: packet.activityFeed == true)
            if packet.sessionAutoYes != true { disableSessionAutoYes(packet.sessionID, reason: "capability unavailable") }
        case "activity":
            guard let activity = packet.activity else { localSessionErrors[packet.sessionID] = "Agent sent an empty activity event."; return }
            do {
                let previous = registry.sessions[packet.sessionID]?.activity.entries.first(where: { $0.id == activity.id })
                try registry.activity(packet.sessionID, entry: activity)
                if activity.agentID == nil, activity.kind == "user", previous == nil { registry.resumeWork(packet.sessionID) }
                if activity.kind == "assistant", activity.agentID == nil, activity.status == "complete", previous?.status != "complete" {
                    registry.output(packet.sessionID, text: activity.detail + "\n\n")
                }
            }
            catch { localSessionErrors[packet.sessionID] = "Invalid activity event; check the original terminal." }
        case "team":
            guard let snapshot = packet.team else {
                registry.invalidateTeam(packet.sessionID)
                localSessionErrors[packet.sessionID] = "Agent sent an empty subagent snapshot."
                return
            }
            do { try registry.team(packet.sessionID, snapshot: snapshot) }
            catch { localSessionErrors[packet.sessionID] = "Invalid subagent status; check the original terminal." }
        case "control_status":
            if let id = packet.commandID, let status = packet.status {
                let previous = steeringWorkspace.receipt(sessionID: packet.sessionID, commandID: id)
                if let target = packet.agentID, target != previous?.agentID { return }
                if let control = phoneControls[id] {
                    guard control.sessionID == packet.sessionID, previous?.agentID == control.agentID else { return }
                    guard let session = registry.sessions[packet.sessionID],
                          previous?.workRevision == session.workRevision, phoneWorkspace.isCurrent(control, session: session) else {
                        finishPhoneControl(id, status: "unknown", detail: "The native session or target changed before acknowledgment.", error: "Stale control generation.")
                        return
                    }
                }
                steeringWorkspace.update(sessionID: packet.sessionID, commandID: id, status: status, text: packet.text ?? "")
                if let receipt = steeringWorkspace.receipt(sessionID: packet.sessionID, commandID: id),
                   receipt.status == status, receipt.status != previous?.status {
                    let accepted = receipt.action == "stop" ? status == "stopped" : ["queued", "received"].contains(status)
                    finishPhoneControl(id, status: status, detail: receipt.detail,
                                       error: accepted ? nil : "Runtime did not accept this control: \(status).")
                }
                if status == "stopped", let previous, previous.action == "stop", previous.agentID == nil,
                   ["sending", "unknown"].contains(previous.status) {
                    registry.acknowledgeStop(packet.sessionID, workRevision: previous.workRevision)
                }
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
            if let phone = mobileReplies[id], phone.sessionID == packet.sessionID {
                let acknowledged = packet.cancelled != true && packet.automatic != true &&
                    packet.decision == phone.decision && packet.permissionOptionID == phone.permissionOptionID &&
                    (packet.answers ?? [:]) == (phone.answers ?? [:]) && packet.feedback == phone.feedback
                finishPhoneReply(id, sessionID: packet.sessionID, error: acknowledged ? nil : "The agent did not confirm this exact phone answer. Check the Mac.")
            }
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
                finishPhoneReply(id, sessionID: packet.sessionID, error: packet.text ?? "The agent could not acknowledge this reply.")
                requestErrors[id] = packet.text ?? "Reply failed. Check the terminal before retrying."
                sending.remove(id)
                automaticallySending.remove(id)
            } else {
                for request in registry.sessions[packet.sessionID]?.requests ?? [] {
                    finishPhoneReply(request.id, sessionID: packet.sessionID, error: packet.text ?? "The agent connection reported an error.")
                }
                agentErrors[packet.sessionID] = packet.text ?? "Agent reported an error."
                sending.subtract(registry.sessions[packet.sessionID]?.requests.map(\.id) ?? [])
                automaticallySending.subtract(registry.sessions[packet.sessionID]?.requests.map(\.id) ?? [])
            }
        default: error = "Unsupported launcher event: \(packet.type)"
        }
        if ["hello", "request", "resolved", "reply", "error", "state", "metadata"].contains(packet.type) { mobile.publish() }
        expirePhoneControls()
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
                let mode = automation.dangerous.contains(id) ? "Dangerous Auto-yes" : "Session Auto-yes"
                try record(session: session, action: scope == "session" ? "\(mode): permission approval dispatched" : "Allow once: verified in-project source read (dispatched)", automatic: true)
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
                self.finishPhoneReply(request.id, sessionID: id, error: self.requestErrors[request.id])
                self.mobile.publish()
                self.onAttentionChange?()
            }
            onAttentionChange?()
        } catch {
            if automatic { disableSessionAutoYes(id, reason: "approval dispatch failed") }
            sending.remove(request.id)
            automaticallySending.remove(request.id)
            self.requestErrors[request.id] = "No approval sent: \(error.localizedDescription)"
        }
        mobile.publish()
    }

    func phoneSnapshot() -> [MobileItem] {
        pending.filter { !automaticallySending.contains($0.request.id) }.map { session, request in
            MobileItem(sessionID: session.id, sessionName: session.name, project: session.projectLabel, agent: session.agent,
                color: String(format: "#%06X", appearance.color(for: session)),
                ticket: mobile.ticket(sessionID: session.id, request: request),
                notificationID: (session.sourceSessionID ?? session.id) + ":" + request.id,
                request: request, fields: RequestContext.fields(from: request.detail, isQuestion: request.kind == "question").map(MobileField.init),
                sending: sending.contains(request.id), error: requestErrors[request.id])
        }
    }

    func phoneWorkspaceSnapshot(watching ids: [String]) throws -> [Data] {
        expirePhoneControls()
        let rows = sessions
        let colors = Dictionary(uniqueKeysWithValues: rows.prefix(256).map { ($0.id, String(format: "#%06X", appearance.color(for: $0))) })
        var messages = [try phoneWorkspace.overview(sessions: rows, colors: colors)]
        for id in ids.prefix(8) {
            guard let session = rows.prefix(256).first(where: { $0.id == id }) else { continue }
            messages.append(try phoneWorkspace.detail(session: session, controls: steeringWorkspace.history[id] ?? [],
                                                     controlsTruncated: steeringWorkspace.truncatedHistory.contains(id)))
        }
        return messages
    }

    func controlFromPhone(_ control: MobileControl) {
        guard let session = registry.sessions[control.sessionID], phoneControls.count < 8 else {
            mobile.completeControl(control.id, status: "failed", detail: "", error: "Session unavailable or too many phone controls pending.")
            return
        }
        do {
            try phoneWorkspace.reserve(control, session: session)
            // Audit metadata only: phone prompt contents remain ephemeral.
            try record(session: session, action: "Phone requested \(control.action) for \(control.agentID.map { "subagent \($0)" } ?? "main agent")", automatic: false)
            guard let commandID = steer(session.id, action: control.action, agentID: control.agentID, phoneText: control.text) else {
                mobile.completeControl(control.id, status: "failed", detail: "", error: "Control could not be dispatched. Check the Mac.")
                return
            }
            phoneControls[commandID] = control
        } catch {
            mobile.completeControl(control.id, status: "failed", detail: "", error: "No control sent: session stale, unsupported, duplicate, or audit unavailable.")
        }
    }

    private func finishPhoneControl(_ commandID: String, status: String, detail: String, error: String?) {
        guard let control = phoneControls.removeValue(forKey: commandID) else { return }
        mobile.completeControl(control.id, commandID: commandID, status: status, detail: detail, error: error)
    }

    private func expirePhoneControls() {
        for (commandID, control) in phoneControls {
            guard let session = registry.sessions[control.sessionID], phoneWorkspace.isCurrent(control, session: session) else {
                finishPhoneControl(commandID, status: "unknown", detail: "Session generation or exact target changed. Check the Mac before retrying.", error: "Control acknowledgment is uncertain.")
                continue
            }
        }
    }

    func replyFromPhone(_ response: MobileReply) {
        guard let session = registry.sessions[response.sessionID],
              let request = session.requests.first(where: { $0.id == response.requestID }),
              mobile.accepts(response, request: request),
              !sending.contains(request.id),
              !mobileReplies.values.contains(where: { $0.id == response.id }),
              registry.canReply(sessionID: session.id, requestID: request.id, decision: response.decision,
                  answers: response.answers ?? [:], permissionOptionID: response.permissionOptionID, feedback: response.feedback) else {
            mobile.complete(response.id, error: "This phone request expired or its answer is invalid. Refresh before replying.")
            return
        }
        do { try record(session: session, action: "Phone requested: \(response.decision)", automatic: false) }
        catch {
            mobile.complete(response.id, error: "No reply sent: approval history could not be saved.")
            requestErrors[request.id] = "Phone reply blocked: \(error.localizedDescription)"
            return
        }
        mobileReplies[request.id] = response
        reply(session: session.id, request: request, decision: response.decision,
              answers: response.answers ?? [:], permissionOptionID: response.permissionOptionID, feedback: response.feedback)
        if !sending.contains(request.id) {
            finishPhoneReply(request.id, sessionID: session.id, error: requestErrors[request.id] ?? "The reply was not sent. Check the Mac.")
        }
    }

    private func finishPhoneReply(_ requestID: String, sessionID: String, error: String?) {
        guard let reply = mobileReplies[requestID], reply.sessionID == sessionID else { return }
        mobileReplies.removeValue(forKey: requestID)
        mobile.complete(reply.id, error: error)
    }
}
