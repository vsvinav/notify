import Foundation

public struct MobileControl: Decodable {
    public let id: String
    public let sessionID: String
    public let ticket: String
    public let action: String
    public let text: String
    public let agentID: String?
    public var isValid: Bool {
        UUID(uuidString: id) != nil && !sessionID.isEmpty && sessionID.count <= 128 &&
        !ticket.isEmpty && ticket.count <= 256 && ["queue", "interrupt", "stop"].contains(action) &&
        text.utf16.count <= 16000 && (action == "stop" ? text.isEmpty : !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) &&
        (agentID.map { !$0.isEmpty && $0.count <= 128 } ?? true)
    }
}

public struct MobileWorkspace {
    private struct Generation: Equatable {
        let revision: UUID
        let connected: Bool
        let steering: Bool
        let chat: Bool
        let stop: Bool
    }
    private var generations: [String: (value: Generation, ticket: String)] = [:]
    private var seen: [String: (sessionID: String, ticket: String)] = [:]
    public init() {}

    public mutating func invalidate() { generations.removeAll(); seen.removeAll() }
    public mutating func ticket(for session: SessionRecord) -> String {
        guard generations[session.id] != nil || generations.count < 256 else { return "" }
        let value = Generation(revision: session.workRevision, connected: session.connected,
                               steering: session.canSteer, chat: session.canChatWithSubagents, stop: session.canStopSubagents)
        if generations[session.id]?.value != value {
            generations[session.id] = (value, UUID().uuidString)
            seen = seen.filter { $0.value.sessionID != session.id }
        }
        return generations[session.id]!.ticket
    }
    public mutating func isCurrent(_ control: MobileControl, session: SessionRecord) -> Bool {
        control.isValid && control.sessionID == session.id && session.connected && control.ticket == ticket(for: session)
    }
    public mutating func accepts(_ control: MobileControl, session: SessionRecord) -> Bool {
        isCurrent(control, session: session) && session.agent == "copilot" &&
            SteeringWorkspace().unavailableReason(session: session, agentID: control.agentID, action: control.action) == nil
    }
    public mutating func reserve(_ control: MobileControl, session: SessionRecord) throws {
        guard accepts(control, session: session), seen[control.id] == nil else { throw ProtocolError.stale }
        guard seen.count < 256 else { throw ProtocolError.oversized }
        seen[control.id] = (session.id, control.ticket)
    }
    public mutating func overview(sessions: [SessionRecord], colors: [String: String]) throws -> Data {
        struct Capabilities: Encodable { let steering: Bool; let subagentChat: Bool; let subagentStop: Bool }
        struct Row: Encodable {
            let id: String; let name: String; let project: String; let agent: String; let color: String
            let state: String; let connected: Bool; let ticket: String; let capabilities: Capabilities
            let runningCount: Int; let idleCount: Int
        }
        struct Snapshot: Encodable {
            let type = "workspace"
            var sessions: [Row]
            let total: Int
            var truncated: Bool
        }
        let retained = Set(sessions.prefix(256).map(\.id))
        generations = generations.filter { retained.contains($0.key) }
        seen = seen.filter { retained.contains($0.value.sessionID) }
        var snapshot = Snapshot(sessions: sessions.prefix(256).map { session in
            Row(id: session.id, name: session.name, project: session.projectLabel, agent: session.agent,
                color: colors[session.id] ?? "#777777", state: session.state, connected: session.connected,
                ticket: ticket(for: session), capabilities: Capabilities(
                    steering: session.connected && session.canSteer, subagentChat: session.connected && session.canChatWithSubagents,
                    subagentStop: session.connected && session.canStopSubagents),
                runningCount: session.team?.runningCount ?? 0, idleCount: session.team?.idleCount ?? 0)
        }, total: sessions.count, truncated: sessions.count > 256)
        while true {
            let data = try Self.encoder().encode(snapshot)
            if data.count <= 1_048_576 { return data }
            guard !snapshot.sessions.isEmpty else { throw ProtocolError.oversized }
            snapshot.sessions.removeLast()
            snapshot.truncated = true
        }
    }
    public mutating func detail(session: SessionRecord, controls: [ControlReceipt], controlsTruncated: Bool = false) throws -> Data {
        struct Receipt: Encodable {
            let id: String; let action: String; let message: String; let status: String; let detail: String
            let agentID: String?; let createdAt: Date
            init(_ r: ControlReceipt) {
                id = r.id; action = r.action; message = r.message; status = r.status; detail = r.detail
                agentID = r.agentID; createdAt = r.createdAt
            }
        }
        struct Detail: Encodable {
            let type = "workspace_detail"
            let sessionID: String
            let ticket: String
            var team: SubagentTeam?
            var activity: [ActivityEntry]
            var controls: [Receipt]
            var truncated: Bool
            enum CodingKeys: String, CodingKey { case type, sessionID, ticket, team, activity, controls, truncated }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(type, forKey: .type); try c.encode(sessionID, forKey: .sessionID); try c.encode(ticket, forKey: .ticket)
                try c.encode(team, forKey: .team); try c.encode(activity, forKey: .activity)
                try c.encode(controls, forKey: .controls); try c.encode(truncated, forKey: .truncated)
            }
        }
        var snapshot = Detail(sessionID: session.id, ticket: ticket(for: session), team: session.team,
                              activity: session.activity.entries, controls: controls.filter { !$0.isManagement }.suffix(100).map(Receipt.init),
                              truncated: session.activity.truncated || session.team?.truncated == true || controls.count > 100 || controlsTruncated)
        while true {
            let data = try Self.encoder().encode(snapshot)
            if data.count <= 1_048_576 { return data }
            snapshot.truncated = true
            if !snapshot.activity.isEmpty || !snapshot.controls.isEmpty {
                let activityDate = snapshot.activity.first?.timestamp ?? "9999"
                let controlDate = snapshot.controls.first.map { ISO8601DateFormatter().string(from: $0.createdAt) } ?? "9999"
                if !snapshot.activity.isEmpty && (snapshot.controls.isEmpty || activityDate < controlDate) { snapshot.activity.removeFirst() }
                else { snapshot.controls.removeFirst() }
            } else {
                snapshot.team = try JSONDecoder().decode(SubagentTeam.self, from: Data("""
                {"agents":[],"runningCount":0,"idleCount":0,"truncated":true,"error":"Team detail exceeds the phone transport limit. View this session on the Mac."}
                """.utf8))
            }
        }
    }
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
