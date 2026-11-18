import Foundation

struct MobilePayloadKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

public struct MobileAutomationPolicy: Codable, Equatable {
    public let ticket: String
    public let offTicket: String
    public let revision: Int
    public let enabled: Bool
    public let normalEnabled: Bool
}

public struct MobileResumeAuthority: Encodable, Equatable {
    public static let maximumRetired = 9_007_199_254_740_991
    public let epoch = UUID().uuidString
    public var retired = 0
    public init() {}
}

public struct MobileSessionActions: Encodable, Equatable {
    public struct ColorChoice: Encodable, Equatable {
        public let name: String
        public let rgb: UInt32
    }
    public var ticket = ""
    public let sourceID: String
    public let group: String
    public let rgb: UInt32
    public let overridden: Bool
    public let colors = SessionAppearance.choices.map { ColorChoice(name: SessionAppearance.names[$0]!, rgb: $0) }
    public let editable: Bool
    public let removable: Bool
    public let resumable: Bool
    public let resumeStatus: String
    public let resumeDetail: String
    public let resumeAuthority: MobileResumeAuthority?
    public let moveUp: String?
    public let moveDown: String?
    public init(session: SessionRecord, appearance: SessionAppearance, editable: Bool, removable: Bool,
                resumable: Bool, resumeStatus: String, resumeDetail: String, moveUp: String?, moveDown: String?,
                resumeAuthority: MobileResumeAuthority? = nil) {
        sourceID = session.sourceSessionID ?? session.id
        group = Self.group(session)
        rgb = appearance.color(for: session)
        overridden = appearance.overrides[sourceID] != nil
        self.editable = editable; self.removable = removable; self.resumable = resumable
        self.resumeStatus = resumeStatus; self.resumeDetail = resumeDetail
        self.resumeAuthority = resumeAuthority
        self.moveUp = moveUp; self.moveDown = moveDown
    }
    public static func group(_ session: SessionRecord) -> String {
        session.isSaved ? "saved" : !session.connected || session.needsSetup ? "not_connected" :
            !session.requests.isEmpty ? "needs_you" : "monitoring"
    }
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
    public let managementTicket: String?
    public let creation: SubagentCreation?
    public let sessionTicket: String?
    public let rgb: UInt32?
    public let targetID: String?
    public let targetTicket: String?
    public var isSessionAction: Bool {
        ["set_session_color", "reset_session_color", "move_session", "remove_session", "resume_session"].contains(action)
    }
    public var isManagement: Bool { ["create_subagent", "remove_subagent", "stop_idle_subagents"].contains(action) }
    public var successStatuses: [String] {
        switch action {
        case "set_session_color": return ["color_saved"]
        case "reset_session_color": return ["color_reset"]
        case "move_session": return ["session_moved"]
        case "remove_session": return ["session_removed"]
        case "resume_session": return ["launched"]
        case "create_subagent": return ["created"]
        case "remove_subagent": return ["removed"]
        case "stop_idle_subagents": return ["cleaned"]
        case "stop": return ["stopped"]
        case "dangerous_auto_yes": return ["applied"]
        case "send": return ["submitted", "received"]
        default: return ["queued", "received"]
        }
    }
    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: MobilePayloadKey.self)
        guard Set(keys.allKeys.map(\.stringValue)).isSubset(of: [
            "type", "id", "sessionID", "ticket", "action", "text", "agentID", "enabled", "policyTicket", "offTicket", "managementTicket", "creation",
            "sessionTicket", "rgb", "targetID", "targetTicket"
        ]) else { throw ProtocolError.invalid }
        if keys.contains(.init("type")), try keys.decode(String.self, forKey: .init("type")) != "control" { throw ProtocolError.invalid }
        id = try keys.decode(String.self, forKey: .init("id"))
        sessionID = try keys.decode(String.self, forKey: .init("sessionID"))
        ticket = try keys.decode(String.self, forKey: .init("ticket"))
        action = try keys.decode(String.self, forKey: .init("action"))
        text = try keys.decode(String.self, forKey: .init("text"))
        agentID = keys.contains(.init("agentID")) ? try keys.decode(String.self, forKey: .init("agentID")) : nil
        enabled = keys.contains(.init("enabled")) ? try keys.decode(Bool.self, forKey: .init("enabled")) : nil
        policyTicket = keys.contains(.init("policyTicket")) ? try keys.decode(String.self, forKey: .init("policyTicket")) : nil
        offTicket = keys.contains(.init("offTicket")) ? try keys.decode(String.self, forKey: .init("offTicket")) : nil
        managementTicket = keys.contains(.init("managementTicket")) ? try keys.decode(String.self, forKey: .init("managementTicket")) : nil
        creation = keys.contains(.init("creation")) ? try keys.decode(SubagentCreation.self, forKey: .init("creation")) : nil
        sessionTicket = keys.contains(.init("sessionTicket")) ? try keys.decode(String.self, forKey: .init("sessionTicket")) : nil
        rgb = keys.contains(.init("rgb")) ? try keys.decode(UInt32.self, forKey: .init("rgb")) : nil
        targetID = keys.contains(.init("targetID")) ? try keys.decode(String.self, forKey: .init("targetID")) : nil
        targetTicket = keys.contains(.init("targetTicket")) ? try keys.decode(String.self, forKey: .init("targetTicket")) : nil
    }
    public var isPolicy: Bool { action == "dangerous_auto_yes" }
    public var isPolicyOff: Bool { isPolicy && enabled == false }
    private var isOffID: Bool { id.dropFirst(14).first == "8" }
    public var isValid: Bool {
        if isSessionAction {
            return UUID(uuidString: id) != nil && id.dropFirst(14).first == "4" &&
                !sessionID.isEmpty && sessionID.count <= 128 && !ticket.isEmpty && ticket.count <= 256 &&
                sessionTicket.map { !$0.isEmpty && $0.count <= 256 } == true &&
                text.isEmpty && agentID == nil && enabled == nil && policyTicket == nil && offTicket == nil &&
                managementTicket == nil && creation == nil &&
                (action == "set_session_color" ? rgb.map { $0 <= 0xFFFFFF } == true : rgb == nil) &&
                (action == "move_session" ? targetID.map { !$0.isEmpty && $0.count <= 128 && $0 != sessionID } == true &&
                    targetTicket.map { !$0.isEmpty && $0.count <= 256 } == true : targetID == nil && targetTicket == nil)
        }
        return sessionTicket == nil && rgb == nil && targetID == nil && targetTicket == nil &&
        UUID(uuidString: id) != nil && !sessionID.isEmpty && sessionID.count <= 128 &&
        !ticket.isEmpty && ticket.count <= 256 &&
        (isPolicy ? enabled != nil && policyTicket.map { !$0.isEmpty && $0.count <= 256 } == true && agentID == nil &&
            offTicket.map { UUID(uuidString: $0) != nil && $0.dropFirst(14).first == "8" } == true &&
            (isPolicyOff ? isOffID && offTicket?.lowercased() == id.lowercased() : !isOffID) :
            (["send", "queue", "interrupt", "stop"].contains(action) || isManagement) && enabled == nil && policyTicket == nil && offTicket == nil) &&
        (action != "send" || agentID == nil) &&
        (isManagement ? id.dropFirst(14).first == "4" && managementTicket.map { !$0.isEmpty && $0.utf16.count <= 256 } == true &&
            (action == "create_subagent" ? creation?.isValid == true && agentID == nil : creation == nil &&
                (action == "remove_subagent" ? agentID != nil : agentID == nil)) : managementTicket == nil && creation == nil) &&
        (isPolicyOff || !isOffID) &&
        text.utf16.count <= 16000 && (action == "stop" || isPolicy || isManagement ? text.isEmpty : !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) &&
        (agentID.map { !$0.isEmpty && $0.count <= 128 } ?? true)
    }
}

public struct MobileWorkspace {
    private struct Generation: Equatable {
        let revision: UUID
        let connected: Bool
        let steering: Bool
        let steeringImmediate: Bool
        let chat: Bool
        let stop: Bool
    }
    private var generations: [String: (value: Generation, ticket: String)] = [:]
    private struct ManagementGeneration: Equatable {
        let revision: UUID; let connected: Bool; let create: Bool; let remove: Bool; let cleanup: Bool
        let types: [String]; let models: [String]
    }
    private var managementGenerations: [String: (value: ManagementGeneration, ticket: String)] = [:]
    private var seen: [String: (sessionID: String, ticket: String)] = [:]
    private var offSeen: [String: (id: String, offTicket: String)] = [:]
    private var sessionGenerations: [String: (value: MobileSessionActions, revision: UUID, cwd: String, agent: String, ticket: String)] = [:]
    public init() {}

    public mutating func invalidate() { generations.removeAll(); managementGenerations.removeAll(); sessionGenerations.removeAll(); seen.removeAll(); offSeen.removeAll() }
    public mutating func sessionActions(_ value: MobileSessionActions, for session: SessionRecord) -> MobileSessionActions {
        guard sessionGenerations[session.id] != nil || sessionGenerations.count < 256 else { return value }
        let previous = sessionGenerations[session.id]
        if previous?.value != value || previous?.revision != session.workRevision ||
            previous?.cwd != session.cwd || previous?.agent != session.agent {
            sessionGenerations[session.id] = (value, session.workRevision, session.cwd, session.agent, UUID().uuidString)
        }
        var result = value
        result.ticket = sessionGenerations[session.id]!.ticket
        return result
    }
    public mutating func reserveSessionAction(_ control: MobileControl, session: SessionRecord,
                                             metadata: MobileSessionActions, target: MobileSessionActions? = nil) throws {
        guard control.isSessionAction && control.isValid && control.sessionID == session.id &&
            control.ticket == ticket(for: session) && control.sessionTicket == metadata.ticket && metadata.editable &&
            (control.action != "remove_session" || metadata.removable && !session.connected) &&
            (control.action != "resume_session" || metadata.resumable && session.isSaved && !session.connected) &&
            (control.action != "move_session" || target?.editable == true && target?.ticket == control.targetTicket &&
                target?.sourceID != metadata.sourceID && target?.group == metadata.group &&
                [metadata.moveUp, metadata.moveDown].compactMap { $0 }.contains(control.targetID ?? "")) else { throw ProtocolError.stale }
        let id = control.id.lowercased()
        guard seen[id] == nil, !offSeen.values.contains(where: { $0.id == id }) else { throw ProtocolError.stale }
        guard seen.count < 256 else { throw ProtocolError.oversized }
        seen[id] = (session.id, control.ticket)
    }
    public mutating func managementTicket(for session: SessionRecord) -> String {
        guard managementGenerations[session.id] != nil || managementGenerations.count < 256 else { return "" }
        let value = ManagementGeneration(revision: session.workRevision, connected: session.connected,
            create: session.canCreateSubagents, remove: session.canRemoveSubagents, cleanup: session.canCleanupIdleSubagents,
            types: session.subagentTypes.sorted(), models: session.subagentModels.sorted())
        if managementGenerations[session.id]?.value != value {
            managementGenerations[session.id] = (value, UUID().uuidString)
        }
        return managementGenerations[session.id]!.ticket
    }
    public mutating func ticket(for session: SessionRecord) -> String {
        guard generations[session.id] != nil || generations.count < 256 else { return "" }
        let value = Generation(revision: session.workRevision, connected: session.connected,
                               steering: session.canSteer, steeringImmediate: session.canSendImmediately,
                               chat: session.canChatWithSubagents, stop: session.canStopSubagents)
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
            // Catalog changes fence new dispatch, not an already-dispatched operation's exact runtime result.
            (!control.isManagement || control.managementTicket == managementTicket(for: session)) &&
            (control.isPolicy ? session.canAutoYes && policy != nil &&
                policy?.offTicket == control.offTicket && (control.isPolicyOff || policy?.ticket == control.policyTicket) :
                SteeringWorkspace().unavailableReason(session: session, agentID: control.agentID, action: control.action) == nil &&
                    (control.creation.map { session.subagentTypes.contains($0.agentType) &&
                        ($0.model.map { session.subagentModels.contains($0) } ?? true) } ?? true))
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
    public mutating func overview(sessions: [SessionRecord], colors: [String: String], policies: [String: MobileAutomationPolicy] = [:],
                                 sessionActions: [String: MobileSessionActions] = [:]) throws -> Data {
        struct Capabilities: Encodable {
            let steering: Bool; let steeringImmediate: Bool; let subagentChat: Bool; let subagentStop: Bool; let dangerousAutoYes: Bool
            let subagentCreate: Bool; let subagentRemove: Bool; let subagentCleanup: Bool
        }
        struct Row: Encodable {
            let id: String; let name: String; let project: String; let agent: String; let color: String
            let state: String; let connected: Bool; let ticket: String; let capabilities: Capabilities
            let runningCount: Int; let idleCount: Int
            let dangerousAutoYes: MobileAutomationPolicy?
            let managementTicket: String; let subagentTypes: [String]; let subagentModels: [String]
            let sessionActions: MobileSessionActions?
        }
        struct Snapshot: Encodable {
            let type = "workspace"
            var sessions: [Row]
            let total: Int
            var truncated: Bool
        }
        let retained = Set(sessions.prefix(256).map(\.id))
        generations = generations.filter { retained.contains($0.key) }
        managementGenerations = managementGenerations.filter { retained.contains($0.key) }
        sessionGenerations = sessionGenerations.filter { retained.contains($0.key) }
        seen = seen.filter { retained.contains($0.value.sessionID) }
        offSeen = offSeen.filter { retained.contains($0.key) }
        var snapshot = Snapshot(sessions: sessions.prefix(256).map { session in
            Row(id: session.id, name: session.name, project: session.projectLabel, agent: session.agent,
                color: colors[session.id] ?? "#777777", state: session.state, connected: session.connected,
                ticket: ticket(for: session), capabilities: Capabilities(
                    steering: session.connected && session.canSteer,
                    steeringImmediate: session.connected && session.canSteer && session.canSendImmediately,
                    subagentChat: session.connected && session.canChatWithSubagents,
                    subagentStop: session.connected && session.canStopSubagents,
                    dangerousAutoYes: session.connected && session.agent == "copilot" && session.canAutoYes && policies[session.id] != nil,
                    subagentCreate: session.connected && session.agent == "copilot" && session.canCreateSubagents && !session.subagentTypes.isEmpty,
                    subagentRemove: session.connected && session.agent == "copilot" && session.canRemoveSubagents,
                    subagentCleanup: session.connected && session.agent == "copilot" && session.canCleanupIdleSubagents),
                runningCount: session.team?.runningCount ?? 0, idleCount: session.team?.idleCount ?? 0, dangerousAutoYes: policies[session.id],
                managementTicket: managementTicket(for: session), subagentTypes: session.subagentTypes, subagentModels: session.subagentModels,
                sessionActions: sessionActions[session.id])
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
