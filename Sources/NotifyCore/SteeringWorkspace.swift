import Foundation

public struct ControlReceipt: Identifiable, Equatable {
    public let id: String
    public let action: String
    public let message: String
    public var status: String
    public var detail: String
    public var agentID: String? = nil
    public var createdAt = Date()
    public let workRevision: UUID
}

public struct SteeringWorkspace {
    public var drafts: [String: String] = [:]
    public private(set) var receipts: [String: ControlReceipt] = [:]
    public private(set) var history: [String: [ControlReceipt]] = [:]
    private var childDrafts: [String: [String: String]] = [:]
    public init() {}

    public func draft(sessionID: String, agentID: String? = nil) -> String {
        if let agentID { return childDrafts[sessionID]?[agentID] ?? "" }
        return drafts[sessionID] ?? ""
    }
    public mutating func setDraft(_ text: String, sessionID: String, agentID: String? = nil) {
        if let agentID { childDrafts[sessionID, default: [:]][agentID] = text }
        else { drafts[sessionID] = text }
    }
    public func receipt(sessionID: String, commandID: String) -> ControlReceipt? {
        history[sessionID]?.first { $0.id == commandID }
    }
    public func unavailableReason(session: SessionRecord, agentID: String?, action: String = "queue") -> String? {
        guard session.connected else { return "Reconnect this session to send messages." }
        if let agentID {
            guard session.team?.error == nil, let agent = session.team?.agents.first(where: { $0.id == agentID }) else {
                return "This subagent is unavailable. Your message will not be sent to another agent."
            }
            guard agent.status == .running || agent.status == .idle else { return "This subagent has ended. Its conversation is read-only." }
            guard action == "stop" ? session.canStopSubagents : session.canChatWithSubagents else {
                return "This connection does not support this subagent control. Reload its Notify extension to check for support."
            }
            guard ["queue", "stop"].contains(action) else { return "Send a message to steer this subagent; main-turn Interrupt does not apply." }
        } else if !session.canSteer {
            return session.agent == "copilot" ? "Reload this terminal's Notify extension to enable messaging." :
                "Messaging this provider's running sessions is not supported yet."
        }
        return nil
    }
    public mutating func begin(session: SessionRecord, action: String, agentID: String? = nil) throws -> String {
        let text = action == "stop" ? "" : draft(sessionID: session.id, agentID: agentID)
        guard unavailableReason(session: session, agentID: agentID, action: action) == nil,
              ["queue", "interrupt", "stop"].contains(action),
              !(history[session.id] ?? []).contains(where: { $0.status == "sending" }), text.utf16.count <= 16000,
              action == "stop" || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProtocolError.invalid }
        // Keep unresolved deliveries so a delayed ACK never lands on a different message.
        var entries = history[session.id] ?? []
        while entries.count >= 100 || entries.reduce(0, { $0 + $1.message.utf8.count }) + text.utf8.count > 524288 {
            guard let index = entries.firstIndex(where: { ["received", "stopped", "cancelled", "failed"].contains($0.status) }) else {
                throw ProtocolError.oversized
            }
            entries.remove(at: index)
        }
        let id = UUID().uuidString
        let receipt = ControlReceipt(id: id, action: action, message: text, status: "sending", detail: "Delivering to Copilot...",
                                     agentID: agentID, workRevision: session.workRevision)
        entries.append(receipt)
        history[session.id] = entries
        if agentID == nil { receipts[session.id] = receipt }
        return id
    }
    public mutating func update(sessionID: String, commandID: String, status: String, text: String) {
        guard let index = history[sessionID]?.firstIndex(where: { $0.id == commandID }),
              var receipt = history[sessionID]?[index],
              ["queued", "received", "stopped", "cancelled", "failed", "unknown"].contains(status) else { return }
        if ["received", "stopped", "cancelled", "failed"].contains(receipt.status) { return }
        receipt.status = status
        receipt.detail = String(text.prefix(2000))
        history[sessionID]?[index] = receipt
        if receipts[sessionID]?.id == commandID { receipts[sessionID] = receipt }
        if ["queued", "received"].contains(status), draft(sessionID: sessionID, agentID: receipt.agentID) == receipt.message {
            setDraft("", sessionID: sessionID, agentID: receipt.agentID)
        }
    }
    public mutating func disconnect(_ id: String) {
        for receipt in history[id] ?? [] where ["sending", "queued"].contains(receipt.status) {
            update(sessionID: id, commandID: receipt.id, status: "unknown", text: "Connection lost. Check the session before resending; delivery may already have occurred.")
        }
    }
}

public struct SessionAutomation {
    public private(set) var enabled = Set<String>()
    public private(set) var dangerous = Set<String>()
    public var activeIDs: Set<String> { enabled.union(dangerous) }
    public init() {}
    public mutating func setEnabled(_ value: Bool, for session: SessionRecord) throws {
        if value {
            guard session.connected, session.canAutoYes else { throw ProtocolError.invalid }
            dangerous.remove(session.id)
            enabled.insert(session.id)
        } else { enabled.remove(session.id) }
    }
    public mutating func setDangerousEnabled(_ value: Bool, for session: SessionRecord) throws {
        if value {
            guard session.connected, session.canAutoYes else { throw ProtocolError.invalid }
            enabled.remove(session.id)
            dangerous.insert(session.id)
        } else { dangerous.remove(session.id) }
    }
    public mutating func disable(_ id: String) {
        enabled.remove(id)
        dangerous.remove(id)
    }
    public func scope(for request: AgentRequest, session: SessionRecord, safeEnabled: Bool, muted: Bool) -> String? {
        guard session.connected, request.kind == "permission" else { return nil }
        if session.canAutoYes && (enabled.contains(session.id) || dangerous.contains(session.id)),
           request.sessionAutoEligible == true { return "session" }
        if safeEnabled && !muted && request.autoEligible { return "safe-read" }
        return nil
    }
}
