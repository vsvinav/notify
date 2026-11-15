import Foundation

public enum SubagentStatus: String, Codable {
    case running, idle, completed, failed, cancelled
}

public struct SubagentRecord: Codable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let task: String
    public let status: SubagentStatus
    public let model: String?
    public let parentKnown: Bool?
    public let parentAgentID: String?

    public var isValid: Bool {
        if let parentAgentID {
            guard parentKnown == true, parentAgentID != id, !parentAgentID.isEmpty,
                  parentAgentID.count <= 128 else { return false }
        }
        return !id.isEmpty && id.count <= 128 && !name.isEmpty && name.count <= 160 &&
            task.count <= 1000 && (model?.count ?? 0) <= 200
    }
}

public struct SubagentTeam: Codable, Equatable {
    public let agents: [SubagentRecord]
    public let runningCount: Int
    public let idleCount: Int
    public let truncated: Bool
    public let error: String?

    public var isValid: Bool {
        guard agents.count <= 100, agents.allSatisfy(\.isValid),
              Set(agents.map(\.id)).count == agents.count,
              (0...1_000_000).contains(runningCount), (0...1_000_000).contains(idleCount),
              (error?.count ?? 0) <= 1000 else { return false }
        let running = agents.filter { $0.status == .running }.count
        let idle = agents.filter { $0.status == .idle }.count
        return truncated ? runningCount >= running && idleCount >= idle : runningCount == running && idleCount == idle
    }
}

public struct SubagentHierarchy {
    public private(set) var roots: [SubagentRecord] = []
    public private(set) var unlinked: [SubagentRecord] = []
    public private(set) var children: [String: [SubagentRecord]] = [:]

    public private(set) var hidden: [SubagentRecord] = []

    public init(agents: [SubagentRecord], hidingInactive: Bool = false) {
        let records = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        hidden = hidingInactive ? agents.filter { $0.status != .running && $0.status != .idle } : []
        let hiddenIDs = Set(hidden.map(\.id))
        func cyclic(_ agent: SubagentRecord) -> Bool {
            var visited = Set([agent.id])
            var current = agent
            while let parentID = current.parentAgentID, let parent = records[parentID] {
                guard visited.insert(parentID).inserted else { return true }
                current = parent
            }
            return false
        }
        for agent in agents where !hiddenIDs.contains(agent.id) {
            if agent.parentKnown != true || cyclic(agent) {
                unlinked.append(agent)
            } else if let parentID = agent.parentAgentID {
                if records[parentID] != nil && !hiddenIDs.contains(parentID) { children[parentID, default: []].append(agent) }
                else { unlinked.append(agent) }
            } else { roots.append(agent) }
        }
    }
}

public struct ActivityEntry: Codable, Identifiable, Equatable {
    public let id: String
    public let kind: String
    public let title: String
    public let detail: String
    public let status: String
    public let timestamp: String
    public let agentID: String?
    public let clientTurnID: String?
    public var byteCount: Int {
        id.utf8.count + title.utf8.count + detail.utf8.count + timestamp.utf8.count +
            (agentID?.utf8.count ?? 0) + (clientTurnID?.utf8.count ?? 0) + 100
    }
    public var isValid: Bool {
        !id.isEmpty && id.count <= 256 && !title.isEmpty && title.count <= 300 &&
        detail.utf8.count <= 65536 && timestamp.count <= 64 && (agentID?.count ?? 0) <= 128 && (clientTurnID?.count ?? 0) <= 128 &&
        ["user", "assistant", "reasoning", "tool", "status"].contains(kind) &&
        ["running", "complete", "failed", "info"].contains(status)
    }
}

public struct SessionActivity {
    public private(set) var entries: [ActivityEntry] = []
    public private(set) var truncated = false
    public private(set) var byteCount = 0
    public init() {}

    public mutating func receive(_ entry: ActivityEntry) throws {
        guard entry.isValid else { throw ProtocolError.invalid }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            byteCount -= entries[index].byteCount
            entries[index] = entry
        } else { entries.append(entry) }
        byteCount += entry.byteCount
        while entries.count > 300 || byteCount > 524288 {
            byteCount -= entries.removeFirst().byteCount
            truncated = true
        }
    }
}
