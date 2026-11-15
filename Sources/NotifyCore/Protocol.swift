import Foundation

public struct LineFramer {
    private var buffer = Data()
    private let limit: Int
    public init(limit: Int = 1_048_576) { self.limit = limit }

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let end = buffer.firstIndex(of: 10) {
            guard buffer.distance(from: buffer.startIndex, to: end) <= limit else { throw ProtocolError.oversized }
            lines.append(Data(buffer[..<end]))
            buffer.removeSubrange(...end)
        }
        guard buffer.count <= limit else { throw ProtocolError.oversized }
        return lines
    }
}

public enum ProtocolError: Error { case oversized, invalid, stale }

public struct QuestionOption: Codable, Hashable {
    public let label: String
    public let description: String
}

public struct AgentQuestion: Codable, Identifiable, Hashable {
    public let id: String
    public let text: String
    public let multiple: Bool
    public let allowFreeform: Bool
    public let required: Bool?
    public let minimumSelections: Int?
    public let options: [QuestionOption]
}

public struct PermissionOption: Codable, Identifiable, Hashable {
    public let id: String
    public let label: String
    public let detail: String

    public var isValid: Bool {
        !id.isEmpty && id.count <= 128 && !label.isEmpty && label.count <= 300 && detail.count <= 4000
    }
}

public struct AgentRequest: Codable, Identifiable, Hashable {
    public let id: String
    public let kind: String
    public let title: String
    public let detail: String
    public let autoEligible: Bool
    public let sessionAutoEligible: Bool?
    public let questions: [AgentQuestion]
    public let permissionOptions: [PermissionOption]?
    public let supportsFeedback: Bool?

    public var isValid: Bool {
        let options = permissionOptions ?? []
        return !id.isEmpty && id.count <= 128 && !title.isEmpty &&
        ["permission", "question"].contains(kind) &&
        (options.isEmpty || (kind == "permission" && options.count <= 12 &&
            options.allSatisfy(\.isValid) && Set(options.map(\.id)).count == options.count)) &&
        (kind != "question" || (!questions.isEmpty && Set(questions.map(\.id)).count == questions.count))
    }

    public func accepts(decision: String, answers: [String: [String]], permissionOptionID: String? = nil, feedback: String? = nil) -> Bool {
        if let feedback {
            guard kind == "permission", supportsFeedback == true, decision == "deny",
                  !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  feedback.utf16.count <= 4000 else { return false }
        }
        if let permissionOptionID {
            guard kind == "permission", decision == "allow",
                  permissionOptions?.contains(where: { $0.id == permissionOptionID }) == true else { return false }
        }
        if decision == "deny" { return true }
        if kind == "permission" { return decision == "allow" }
        guard decision == "answer", !questions.isEmpty else { return false }
        return questions.allSatisfy { question in
            if question.required == false && (answers[question.id]?.isEmpty ?? true) { return true }
            guard let values = answers[question.id],
                  values.count >= (question.multiple ? question.minimumSelections ?? 1 : 1),
                  question.multiple || values.count == 1,
                  Set(values).count == values.count else { return false }
            return values.allSatisfy { value in
                !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count < 65_536 &&
                (question.allowFreeform || question.options.contains { option in option.label == value })
            }
        }
    }
}

public struct AgentPacket: Decodable {
    public let type: String
    public let sessionID: String
    public let token: String?
    public let agent: String?
    public let cwd: String?
    public let pid: Int?
    public let state: String?
    public let text: String?
    public let request: AgentRequest?
    public let requestID: String?
    public let decision: String?
    public let permissionOptionID: String?
    public let answers: [String: [String]]?
    public let feedback: String?
    public let automatic: Bool?
    public let cancelled: Bool?
    public let title: String?
    public let sourceSessionID: String?
    public let steering: Bool?
    public let sessionAutoYes: Bool?
    public let commandID: String?
    public let agentID: String?
    public let status: String?
    public let activity: ActivityEntry?
    public let activityFeed: Bool?
    public let team: SubagentTeam?
    public let subagentChat: Bool?
    public let subagentStop: Bool?
    public let subagentCreate: Bool?
    public let subagentRemove: Bool?
    public let subagentTypes: [String]?
    public let subagentModels: [String]?
}

public struct SessionRecord: Identifiable {
    public let id: String
    public let agent: String
    public var cwd: String
    public var title = ""
    public var synopsis = ""
    public var sourceSessionID: String?
    public var canSteer = false
    public var canChatWithSubagents = false
    public var canStopSubagents = false
    public var canCreateSubagents = false
    public var canRemoveSubagents = false
    public var subagentTypes: [String] = []
    public var subagentModels: [String] = []
    public var stopped = false
    public var workRevision = UUID()
    public var canAutoYes = false
    public var hasActivityFeed = false
    public var activity = SessionActivity()
    public var team: SubagentTeam?
    public var ownerPID: Int32?
    public var isSaved = false
    public var connected = true
    public var needsSetup = false
    public var baseState = "ready"
    public var summary = ""
    public var output = ""
    public var requests: [AgentRequest] = []
    public var updated = Date()
    public var name: String { !title.isEmpty ? title : (cwd.isEmpty ? "\(agent.capitalized) / \(id.prefix(8))" : URL(fileURLWithPath: cwd).lastPathComponent) }
    public var projectLabel: String { cwd.isEmpty ? String(id.prefix(8)) : URL(fileURLWithPath: cwd).lastPathComponent }
    public var state: String { isSaved ? "saved" : (needsSetup ? "setup" : (!connected ? "disconnected" : (!requests.isEmpty ? "waiting" : baseState))) }
    public var workHeadline: String {
        if !connected && !isSaved { return "Disconnected — activity may be out of date" }
        if needsSetup { return "Connect to see activity and decisions" }
        if let request = requests.first { return request.title }
        if let event = activity.entries.last(where: { $0.kind == "tool" }) {
            if baseState == "ready" { return "Last action: \(event.title)" }
            return "\(event.status == "failed" ? "Tool failed: " : (event.status == "running" ? "Running: " : "Last action: "))\(event.title)"
        }
        return summary.isEmpty ? (isSaved ? "Saved conversation" : "Waiting for observed activity") : summary
    }
    public var lastObservedAt: Date? {
        guard let value = activity.entries.last?.timestamp else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    public init(id: String, agent: String, cwd: String) {
        self.id = id; self.agent = agent; self.cwd = cwd
    }
}
