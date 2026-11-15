import Foundation

public struct SubagentCreation {
    public let name: String
    public let agentType: String
    public let prompt: String
    public let model: String?
    public init(name: String, agentType: String, prompt: String, model: String? = nil) {
        self.name = name
        self.agentType = agentType
        self.prompt = prompt
        self.model = model
    }
    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf16.count <= 160 &&
        !agentType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && agentType.utf16.count <= 128 &&
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && prompt.utf16.count <= 16000 &&
        (model.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf16.count <= 200 } ?? true)
    }
}

public struct ControlReceipt: Identifiable, Equatable {
    public let id: String
    public let action: String
    public let message: String
    public var status: String
    public var detail: String
    public var agentID: String? = nil
    public var createdAt = Date()
    public let workRevision: UUID
    public var preservesDraft = false
    public var agentName: String? = nil
    public var agentType: String? = nil
    public var model: String? = nil
    public var isManagement: Bool { ["create_subagent", "remove_subagent", "stop_idle_subagents"].contains(action) }
}

public struct SteeringWorkspace {
    public var drafts: [String: String] = [:]
    public private(set) var receipts: [String: ControlReceipt] = [:]
    public private(set) var history: [String: [ControlReceipt]] = [:]
    public private(set) var truncatedHistory = Set<String>()
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
        if action == "stop_idle_subagents" {
            guard agentID == nil, session.agent == "copilot", session.canCleanupIdleSubagents else {
                return "Idle cleanup is unavailable. Copilot needs the updated Notify extension; Claude hooks do not support stopping."
            }
            return session.team != nil && session.team?.error == nil ? nil : "Wait for a valid team snapshot before cleanup."
        }
        if action == "create_subagent" {
            return agentID == nil && session.canCreateSubagents && !session.subagentTypes.isEmpty ? nil :
                "This connection cannot create subagents. Reload its Notify extension to check for support."
        }
        if action == "remove_subagent" {
            guard let agentID, session.team?.error == nil,
                  let agent = session.team?.agents.first(where: { $0.id == agentID }) else {
                return "This helper is unavailable. Refresh its team before removing it."
            }
            guard [.completed, .failed, .cancelled].contains(agent.status) else {
                return "Only ended helpers can be removed. Stop an active or idle helper separately first."
            }
            return session.canRemoveSubagents ? nil : "Reload this session's Notify extension to enable removal."
        }
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
    public mutating func begin(session: SessionRecord, action: String, agentID: String? = nil, creation: SubagentCreation? = nil, phoneText: String? = nil) throws -> String {
        if phoneText != nil && (!["queue", "interrupt", "stop"].contains(action) || creation != nil) { throw ProtocolError.invalid }
        if action == "create_subagent" {
            guard let creation, creation.isValid, session.subagentTypes.contains(creation.agentType), agentID == nil else {
                throw ProtocolError.invalid
            }
            if let model = creation.model, !session.subagentModels.contains(model) { throw ProtocolError.invalid }
        } else if creation != nil { throw ProtocolError.invalid }
        let emptyMessage = ["stop", "remove_subagent", "stop_idle_subagents"].contains(action)
        let text = phoneText ?? creation?.prompt ?? (emptyMessage ? "" : draft(sessionID: session.id, agentID: agentID))
        guard unavailableReason(session: session, agentID: agentID, action: action) == nil,
              ["queue", "interrupt", "stop", "create_subagent", "remove_subagent", "stop_idle_subagents"].contains(action),
              !(history[session.id] ?? []).contains(where: { $0.status == "sending" }), text.utf16.count <= 16000,
              emptyMessage || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProtocolError.invalid }
        // Keep unresolved deliveries so a delayed ACK never lands on a different message.
        var entries = history[session.id] ?? []
        while entries.count >= 100 || entries.reduce(0, { $0 + $1.message.utf8.count }) + text.utf8.count > 524288 {
            guard let index = entries.firstIndex(where: { ["received", "stopped", "cancelled", "failed", "created", "removed", "cleaned"].contains($0.status) }) else {
                throw ProtocolError.oversized
            }
            entries.remove(at: index)
            truncatedHistory.insert(session.id)
        }
        let id = UUID().uuidString
        let receipt = ControlReceipt(id: id, action: action, message: text, status: "sending", detail: "Delivering to Copilot...",
                                     agentID: agentID, workRevision: session.workRevision, preservesDraft: phoneText != nil,
                                     agentName: creation?.name, agentType: creation?.agentType, model: creation?.model)
        entries.append(receipt)
        history[session.id] = entries
        if agentID == nil { receipts[session.id] = receipt }
        return id
    }
    public mutating func update(sessionID: String, commandID: String, status: String, text: String) {
        guard let index = history[sessionID]?.firstIndex(where: { $0.id == commandID }),
              var receipt = history[sessionID]?[index],
              ["queued", "received", "stopped", "cancelled", "failed", "unknown", "created", "removed", "cleaned"].contains(status) else { return }
        if ["received", "stopped", "cancelled", "failed", "created", "removed", "cleaned"].contains(receipt.status) { return }
        if receipt.isManagement {
            let completed = receipt.action == "create_subagent" ? "created" : receipt.action == "remove_subagent" ? "removed" : "cleaned"
            guard ["failed", "unknown", completed].contains(status) else { return }
        } else if ["created", "removed", "cleaned"].contains(status) { return }
        if receipt.action == "stop", ["queued", "received"].contains(status) { return }
        if receipt.action != "stop", status == "stopped" { return }
        receipt.status = status
        receipt.detail = String(text.prefix(2000))
        history[sessionID]?[index] = receipt
        if receipts[sessionID]?.id == commandID { receipts[sessionID] = receipt }
        if !receipt.preservesDraft, ["queued", "received"].contains(status), draft(sessionID: sessionID, agentID: receipt.agentID) == receipt.message {
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
