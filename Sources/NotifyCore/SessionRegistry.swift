import Foundation

public struct SessionRegistry {
    public private(set) var sessions: [String: SessionRecord] = [:]
    public init() {}

    public mutating func catalog(_ found: [SavedCopilot]) {
        let ids = Set(found.map(\.id))
        for row in sessions.values where row.isSaved && !ids.contains(row.sourceSessionID ?? row.id) {
            sessions.removeValue(forKey: row.id)
        }
        for item in found {
            let rowID = sessions.values.first { $0.sourceSessionID == item.id }?.id ?? item.id
            var row = sessions[rowID] ?? SessionRecord(id: rowID, agent: "copilot", cwd: item.cwd)
            if sessions[rowID]?.connected != true {
                row.connected = false
                row.isSaved = item.pid == nil
                row.needsSetup = item.pid != nil
                row.updated = item.lastActivity ?? .distantPast
                row.summary = item.pid == nil ? "Saved chat. Resume in iTerm2 to continue." : "Running in iTerm2 or another terminal. Connect its Notify extension."
                if row.isSaved { row.requests.removeAll() }
            }
            row.ownerPID = item.pid
            if !item.title.isEmpty { row.title = item.title }
            if !item.cwd.isEmpty { row.cwd = item.cwd }
            if !item.synopsis.isEmpty { row.synopsis = item.synopsis }
            sessions[rowID] = row
        }
    }

    public mutating func discover(_ found: [DiscoveredCopilot]) {
        let live = Set(found.map(\.id))
        for session in sessions.values where session.needsSetup && !live.contains(session.sourceSessionID ?? session.id) {
            sessions.removeValue(forKey: session.id)
        }
        for foundSession in found {
            let rowID = sessions.values.first { $0.sourceSessionID == foundSession.id }?.id ?? foundSession.id
            var session = sessions[rowID] ?? SessionRecord(id: foundSession.id, agent: "copilot", cwd: foundSession.cwd)
            if sessions[rowID]?.connected != true {
                session.connected = false
                session.needsSetup = true
                session.summary = "Running in terminal (PID \(foundSession.pid)). Connect the Notify extension."
            }
            if !foundSession.title.isEmpty { session.title = foundSession.title }
            if !foundSession.cwd.isEmpty { session.cwd = foundSession.cwd }
            if !foundSession.synopsis.isEmpty { session.synopsis = foundSession.synopsis }
            session.ownerPID = foundSession.pid
            sessions[session.id] = session
        }
    }
    public mutating func register(id: String, agent: String, cwd: String) {
        let previous = sessions[id]
        var session = SessionRecord(id: id, agent: agent, cwd: cwd)
        session.output = previous?.output ?? ""
        session.title = previous?.title ?? ""
        session.synopsis = previous?.synopsis ?? ""
        session.sourceSessionID = previous?.sourceSessionID
        session.activity = previous?.activity ?? SessionActivity()
        session.ownerPID = previous?.ownerPID
        if cwd.isEmpty { session.cwd = previous?.cwd ?? "" }
        sessions[id] = session
    }
    public mutating func title(_ id: String, text: String, sourceSessionID: String? = nil) {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sessions[id]?.title = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        }
        if let sourceSessionID, UUID(uuidString: sourceSessionID) != nil {
            sessions[id]?.sourceSessionID = sourceSessionID
            for source in sessions.values where source.id != id && !source.connected &&
                (source.id == sourceSessionID || source.sourceSessionID == sourceSessionID) {
                if sessions[id]?.title.isEmpty == true { sessions[id]?.title = source.title }
                sessions[id]?.synopsis = source.synopsis
                sessions[id]?.ownerPID = source.ownerPID
                sessions.removeValue(forKey: source.id)
            }
        }
    }
    public mutating func capabilities(_ id: String, steering: Bool, autoYes: Bool, subagentChat: Bool = false, subagentStop: Bool = false) {
        guard sessions[id]?.connected == true, sessions[id]?.agent == "copilot" else { return }
        sessions[id]?.canSteer = steering
        sessions[id]?.canAutoYes = autoYes
        sessions[id]?.canChatWithSubagents = subagentChat
        sessions[id]?.canStopSubagents = subagentStop
    }
    public mutating func resumeWork(_ id: String) {
        guard sessions[id]?.connected == true else { return }
        sessions[id]?.stopped = false
        sessions[id]?.workRevision = UUID()
    }
    public mutating func acknowledgeStop(_ id: String, workRevision: UUID) {
        guard sessions[id]?.connected == true, sessions[id]?.workRevision == workRevision else { return }
        sessions[id]?.stopped = true
    }
    public mutating func activityCapability(_ id: String, enabled: Bool) {
        sessions[id]?.hasActivityFeed = enabled
    }
    public mutating func activity(_ id: String, entry: ActivityEntry) throws {
        guard sessions[id]?.connected == true else { throw ProtocolError.stale }
        try sessions[id]?.activity.receive(entry)
    }
    public mutating func team(_ id: String, snapshot: SubagentTeam) throws {
        guard sessions[id]?.connected == true else { throw ProtocolError.stale }
        guard snapshot.isValid else { throw ProtocolError.invalid }
        sessions[id]?.team = snapshot
    }
    public mutating func add(_ request: AgentRequest, to id: String) throws {
        guard request.isValid, var session = sessions[id], session.connected else { throw ProtocolError.invalid }
        guard !session.requests.contains(where: { $0.id == request.id }) else { return }
        guard session.requests.count < 100 else { throw ProtocolError.oversized }
        session.requests.append(request)
        session.updated = Date()
        sessions[id] = session
    }
    public mutating func state(_ id: String, state: String, text: String) {
        guard ["ready", "working", "error", "starting"].contains(state) else { return }
        sessions[id]?.baseState = state
        sessions[id]?.summary = String(text.suffix(4000))
        sessions[id]?.updated = Date()
    }
    public mutating func output(_ id: String, text: String) {
        guard var session = sessions[id] else { return }
        session.output = String((session.output + text).suffix(32_000))
        sessions[id] = session
    }
    public mutating func resolve(sessionID: String, requestID: String) {
        sessions[sessionID]?.requests.removeAll { $0.id == requestID }
    }
    public mutating func disconnect(_ id: String) { sessions[id]?.connected = false }
    public mutating func remove(_ id: String) {
        if sessions[id]?.connected == false { sessions.removeValue(forKey: id) }
    }
    public func canReply(sessionID: String, requestID: String, decision: String, answers: [String: [String]], permissionOptionID: String? = nil, feedback: String? = nil) -> Bool {
        guard let session = sessions[sessionID], session.connected,
              let request = session.requests.first(where: { $0.id == requestID }) else { return false }
        return request.accepts(decision: decision, answers: answers, permissionOptionID: permissionOptionID, feedback: feedback)
    }
}
