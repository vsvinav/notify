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

    public struct Row: Identifiable {
        public enum Kind {
            case agent(SubagentRecord)
            case inactive(count: Int, failed: Int)
            case unlinked
        }
        public let id: String
        public let parentID: String?
        public let depth: Int
        public let kind: Kind
    }

    public func outline(expandedInactive: Set<String> = [], collapsed: Set<String> = []) -> [Row] {
        var summaries: [String: (active: Bool, count: Int, failed: Int)] = [:]
        func summarize(_ agent: SubagentRecord) {
            var result = (active: agent.status == .running || agent.status == .idle,
                          count: 1, failed: agent.status == .failed ? 1 : 0)
            for child in children[agent.id] ?? [] {
                summarize(child)
                if let summary = summaries[child.id] {
                    result.active = result.active || summary.active
                    result.count += summary.count
                    result.failed += summary.failed
                }
            }
            summaries[agent.id] = result
        }
        (roots + unlinked).forEach(summarize)
        var rows: [Row] = []
        func appendAgent(_ agent: SubagentRecord, parentID: String?, depth: Int, includeInactive: Bool) {
            let id = "agent:\(agent.id)"
            rows.append(Row(id: id, parentID: parentID, depth: depth, kind: .agent(agent)))
            if !collapsed.contains(agent.id) {
                appendGroup(children[agent.id] ?? [], groupID: id, parentID: id,
                            depth: depth + 1, includeInactive: includeInactive)
            }
        }
        func appendGroup(_ agents: [SubagentRecord], groupID: String, parentID: String?,
                         depth: Int, includeInactive: Bool = false) {
            let inactive = agents.filter { summaries[$0.id]?.active == false }
            for agent in agents where summaries[agent.id]?.active == true {
                appendAgent(agent, parentID: parentID, depth: depth, includeInactive: includeInactive)
            }
            guard !inactive.isEmpty else { return }
            let id = "inactive:\(groupID)"
            if !includeInactive {
                let count = inactive.reduce(0) { $0 + (summaries[$1.id]?.count ?? 0) }
                let failed = inactive.reduce(0) { $0 + (summaries[$1.id]?.failed ?? 0) }
                rows.append(Row(id: id, parentID: parentID, depth: depth, kind: .inactive(count: count, failed: failed)))
            }
            if includeInactive || expandedInactive.contains(id) {
                for agent in inactive {
                    appendAgent(agent, parentID: parentID, depth: depth, includeInactive: true)
                }
            }
        }
        appendGroup(roots, groupID: "root", parentID: "root", depth: 1)
        if !unlinked.isEmpty {
            rows.append(Row(id: "unlinked", parentID: nil, depth: 0, kind: .unlinked))
            appendGroup(unlinked, groupID: "unlinked", parentID: nil, depth: 0)
        }
        return rows
    }

    public init(agents: [SubagentRecord]) {
        let records = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func cyclic(_ agent: SubagentRecord) -> Bool {
            var visited = Set([agent.id])
            var current = agent
            while let parentID = current.parentAgentID, let parent = records[parentID] {
                guard visited.insert(parentID).inserted else { return true }
                current = parent
            }
            return false
        }
        for agent in agents {
            if agent.parentKnown != true || cyclic(agent) {
                unlinked.append(agent)
            } else if let parentID = agent.parentAgentID {
                if records[parentID] != nil { children[parentID, default: []].append(agent) }
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
