import Foundation

public struct ControlReceipt {
    public let id: String
    public let action: String
    public let message: String
    public var status: String
    public var detail: String
}

public struct SteeringWorkspace {
    public var drafts: [String: String] = [:]
    public private(set) var receipts: [String: ControlReceipt] = [:]
    public init() {}

    public mutating func begin(session: SessionRecord, action: String) throws -> String {
        let text = action == "stop" ? "" : drafts[session.id] ?? ""
        guard session.connected, session.canSteer, ["queue", "interrupt", "stop"].contains(action),
              receipts[session.id]?.status != "sending", text.utf16.count <= 16000,
              action == "stop" || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProtocolError.invalid }
        let id = UUID().uuidString
        receipts[session.id] = ControlReceipt(id: id, action: action, message: text, status: "sending", detail: "Delivering to Copilot...")
        return id
    }
    public mutating func update(sessionID: String, commandID: String, status: String, text: String) {
        guard var receipt = receipts[sessionID], receipt.id == commandID,
              ["queued", "received", "stopped", "cancelled", "failed", "unknown"].contains(status) else { return }
        if receipt.status == "received" && ["queued", "unknown"].contains(status) { return }
        receipt.status = status
        receipt.detail = String(text.prefix(2000))
        receipts[sessionID] = receipt
        if ["queued", "received"].contains(status), drafts[sessionID] == receipt.message {
            drafts[sessionID] = ""
        }
    }
    public mutating func disconnect(_ id: String) {
        guard let receipt = receipts[id], ["sending", "queued"].contains(receipt.status) else { return }
        update(sessionID: id, commandID: receipt.id, status: "unknown", text: "Connection lost. Check the session before resending; delivery may already have occurred.")
    }
}

public struct SessionAutomation {
    public private(set) var enabled = Set<String>()
    public init() {}
    public mutating func setEnabled(_ value: Bool, for session: SessionRecord) throws {
        if value {
            guard session.connected, session.canAutoYes else { throw ProtocolError.invalid }
            enabled.insert(session.id)
        } else { enabled.remove(session.id) }
    }
    public mutating func disable(_ id: String) { enabled.remove(id) }
    public func scope(for request: AgentRequest, session: SessionRecord, safeEnabled: Bool, muted: Bool) -> String? {
        guard session.connected, request.kind == "permission" else { return nil }
        if session.canAutoYes && enabled.contains(session.id) && request.sessionAutoEligible == true { return "session" }
        if safeEnabled && !muted && request.autoEligible { return "safe-read" }
        return nil
    }
}
