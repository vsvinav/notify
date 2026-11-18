import Foundation

public struct MobileAutomationPolicy: Codable, Equatable {
    public let ticket: String
    public let offTicket: String
    public let revision: Int
    public let enabled: Bool
    public let normalEnabled: Bool
}

public struct MobileControl: Decodable {
    public let id: String
    public let sessionID: String
    public let ticket: String
    public let action: String
    public let text: String
    public let agentID: String?
    public let enabled: Bool?
    public let policyTicket: String?
    public let offTicket: String?
    public var isPolicy: Bool { action == "dangerous_auto_yes" }
    public var isPolicyOff: Bool { isPolicy && enabled == false }
    private var isOffID: Bool { id.dropFirst(14).first == "8" }
    public var isValid: Bool {
        UUID(uuidString: id) != nil && !sessionID.isEmpty && sessionID.count <= 128 &&
        !ticket.isEmpty && ticket.count <= 256 &&
        (isPolicy ? enabled != nil && policyTicket.map { !$0.isEmpty && $0.count <= 256 } == true && agentID == nil &&
            offTicket.map { UUID(uuidString: $0) != nil && $0.dropFirst(14).first == "8" } == true &&
            (isPolicyOff ? isOffID && offTicket?.lowercased() == id.lowercased() : !isOffID) :
            ["queue", "interrupt", "stop"].contains(action) && enabled == nil && policyTicket == nil && offTicket == nil) &&
        (isPolicyOff || !isOffID) &&
        text.utf16.count <= 16000 && (action == "stop" || isPolicy ? text.isEmpty : !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) &&
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
    private var offSeen: [String: (id: String, offTicket: String)] = [:]
    public init() {}

    public mutating func invalidate() { generations.removeAll(); seen.removeAll(); offSeen.removeAll() }
    public mutating func ticket(for session: SessionRecord) -> String {
        guard generations[session.id] != nil || generations.count < 256 else { return "" }
        let value = Generation(revision: session.workRevision, connected: session.connected,
                               steering: session.canSteer, chat: session.canChatWithSubagents, stop: session.canStopSubagents)
        if generations[session.id]?.value != value {
            generations[session.id] = (value, UUID().uuidString)
            seen = seen.filter { $0.value.sessionID != session.id }
            offSeen.removeValue(forKey: session.id)
        }
        return generations[session.id]!.ticket
    }
    public mutating func isCurrent(_ control: MobileControl, session: SessionRecord) -> Bool {
        control.isValid && control.sessionID == session.id && session.connected && control.ticket == ticket(for: session)
    }
    public mutating func accepts(_ control: MobileControl, session: SessionRecord, policy: MobileAutomationPolicy? = nil) -> Bool {
        isCurrent(control, session: session) && session.agent == "copilot" &&
            (control.isPolicy ? session.canAutoYes && policy != nil &&
                policy?.offTicket == control.offTicket && (control.isPolicyOff || policy?.ticket == control.policyTicket) :
                SteeringWorkspace().unavailableReason(session: session, agentID: control.agentID, action: control.action) == nil)
    }
    public mutating func reserve(_ control: MobileControl, session: SessionRecord, policy: MobileAutomationPolicy? = nil) throws {
        let id = control.id.lowercased()
        guard accepts(control, session: session, policy: policy), seen[id] == nil,
              !offSeen.values.contains(where: { $0.id == id }) else { throw ProtocolError.stale }
        if control.isPolicyOff {
            // A consumed Off epoch cannot authorize work again, even after its single record is retired.
            guard offSeen[session.id]?.offTicket != control.offTicket else { throw ProtocolError.stale }
            offSeen[session.id] = (id, control.offTicket!)
            return
        }
        guard seen.count < 256 else { throw ProtocolError.oversized }
        seen[id] = (session.id, control.ticket)
    }
    public mutating func overview(sessions: [SessionRecord], colors: [String: String], policies: [String: MobileAutomationPolicy] = [:]) throws -> Data {
        struct Capabilities: Encodable { let steering: Bool; let subagentChat: Bool; let subagentStop: Bool; let dangerousAutoYes: Bool }
        struct Row: Encodable {
            let id: String; let name: String; let project: String; let agent: String; let color: String
            let state: String; let connected: Bool; let ticket: String; let capabilities: Capabilities
            let runningCount: Int; let idleCount: Int
            let dangerousAutoYes: MobileAutomationPolicy?
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
        offSeen = offSeen.filter { retained.contains($0.key) }
        var snapshot = Snapshot(sessions: sessions.prefix(256).map { session in
            Row(id: session.id, name: session.name, project: session.projectLabel, agent: session.agent,
                color: colors[session.id] ?? "#777777", state: session.state, connected: session.connected,
                ticket: ticket(for: session), capabilities: Capabilities(
                    steering: session.connected && session.canSteer, subagentChat: session.connected && session.canChatWithSubagents,
                    subagentStop: session.connected && session.canStopSubagents,
                    dangerousAutoYes: session.connected && session.agent == "copilot" && session.canAutoYes && policies[session.id] != nil),
                runningCount: session.team?.runningCount ?? 0, idleCount: session.team?.idleCount ?? 0, dangerousAutoYes: policies[session.id])
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
