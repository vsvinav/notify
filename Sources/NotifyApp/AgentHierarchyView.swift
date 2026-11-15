import SwiftUI
import NotifyCore

struct AgentHierarchyView: View {
    @ObservedObject var store: Store
    let session: SessionRecord
    var selectedAgentID: String?
    let selectAgent: (String?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedInactive: Set<String> = []
    @State private var collapsed: Set<String> = []

    private var animate: Bool { store.centerVisible && !reduceMotion }

    var body: some View {
        let hierarchy = SubagentHierarchy(agents: session.team?.agents ?? [])
        let rows = hierarchy.outline(expandedInactive: expandedInactive, collapsed: collapsed)
        let accent = store.sessionColor(session)
        let current = session.connected && session.team?.error == nil
        VStack(alignment: .leading, spacing: 8) {
            Text("Agent hierarchy").font(WorkspaceType.text(25, strong: true))
            Text("Select an agent to chat. Expand inactive groups to see past work.")
                .font(WorkspaceType.text(13)).foregroundStyle(Palette.muted)
            if let team = session.team {
                Text(team.error ?? (current ? "\(team.runningCount) running · \(team.idleCount) ready for follow-up" :
                    "Last reported hierarchy. Reconnect for current status."))
                    .font(WorkspaceType.text(12)).foregroundStyle(team.error == nil ? Palette.muted : Palette.amber)
                if team.truncated {
                    Text("Showing up to 100 agents; counts include the full team. Some parents may be outside this view.")
                        .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
                }
            } else {
                Text("This connection has not reported a team yet.")
                    .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
            }
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Button { selectAgent(nil) } label: {
                        HierarchyNode(name: "Main agent", task: session.name, status: AgentPresence(session: session).title,
                                      presence: AgentPresence(session: session), accent: accent, lead: true)
                    }.buttonStyle(AgentSelectionStyle(selected: selectedAgentID == nil, accent: accent))
                        .accessibilityLabel("Chat with main agent")
                        .anchorPreference(key: HierarchyAnchors.self, value: .bounds) { ["root": $0] }
                    ForEach(rows) { row in
                        switch row.kind {
                        case .agent(let agent):
                            agentRow(agent, row: row, hierarchy: hierarchy, current: current, accent: accent)
                                .padding(.leading, CGFloat(min(row.depth, 3)) * 20)
                        case .inactive(let count, let failed):
                            Button {
                                withAnimation(animate ? .easeOut(duration: 0.2) : nil) {
                                    if !expandedInactive.insert(row.id).inserted { expandedInactive.remove(row.id) }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Label(expandedInactive.contains(row.id) ? "Hide \(count) inactive" : "+\(count) inactive",
                                          systemImage: expandedInactive.contains(row.id) ? "chevron.down" : "chevron.right")
                                    if failed > 0 { Text("\(failed) failed").foregroundStyle(Palette.error) }
                                }.font(WorkspaceType.text(12)).padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(Palette.background, in: Capsule())
                            }.buttonStyle(.plain)
                                .help("Completed, failed or stopped agents, including their inactive descendants.")
                                .anchorPreference(key: HierarchyAnchors.self, value: .bounds) { [row.id: $0] }
                                .padding(.leading, CGFloat(min(row.depth, 3)) * 20)
                        case .unlinked:
                            Text("Parent not reported or outside this view")
                                .font(WorkspaceType.text(15, strong: true)).padding(.top, 14)
                                .help("No connection is drawn unless the reported relationship can be shown safely.")
                        }
                    }
                }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
                    .backgroundPreferenceValue(HierarchyAnchors.self) { anchors in
                        GeometryReader { positions in
                            Path { path in
                                for row in rows {
                                    guard let parent = row.parentID, let a = anchors[parent], let b = anchors[row.id] else { continue }
                                    let start = positions[a], end = positions[b]
                                    let x = end.minX - 12
                                    path.addLines([CGPoint(x: start.minX + 8, y: start.maxY),
                                                   CGPoint(x: x, y: start.maxY + 4),
                                                   CGPoint(x: x, y: end.midY),
                                                   CGPoint(x: end.minX, y: end.midY)])
                                }
                            }.stroke(Palette.line, style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                                .accessibilityHidden(true)
                        }
                    }
                    .animation(animate ? .easeOut(duration: 0.2) : nil, value: session.team?.agents)
            }.scrollIndicators(.visible)
        }.foregroundStyle(Palette.ink)
    }

    private func agentRow(_ agent: SubagentRecord, row: SubagentHierarchy.Row,
                          hierarchy: SubagentHierarchy, current: Bool, accent: Color) -> some View {
        let children = hierarchy.children[agent.id] ?? []
        let state: AgentPresence = agent.status == .cancelled ? .stopped : !current ? .disconnected :
            agent.status == .running ? .working : agent.status == .idle ? .resting :
            agent.status == .failed ? .error : .finished
        let parent = agent.parentAgentID.flatMap { id in session.team?.agents.first { $0.id == id }?.name }
        return VStack(alignment: .leading, spacing: 4) {
            Button { selectAgent(agent.id) } label: {
                HierarchyNode(name: agent.name, task: agent.task,
                              status: current ? (agent.status == .cancelled ? "Stopped" : agent.status.rawValue.capitalized) :
                                "Last seen: \(agent.status.rawValue)", presence: state, accent: accent,
                              parent: row.depth > 3 ? parent : nil)
            }.buttonStyle(AgentSelectionStyle(selected: selectedAgentID == agent.id, accent: accent))
                .disabled(agent.status == .cancelled)
                .accessibilityLabel(agent.status == .cancelled ? "\(agent.name), stopped" : "Chat with \(agent.name)")
                .anchorPreference(key: HierarchyAnchors.self, value: .bounds) { [row.id: $0] }
            if !children.isEmpty {
                Button {
                    withAnimation(animate ? .easeOut(duration: 0.2) : nil) {
                        if !collapsed.insert(agent.id).inserted { collapsed.remove(agent.id) }
                    }
                } label: {
                    Label("\(collapsed.contains(agent.id) ? "Show" : "Hide") \(children.count) branch\(children.count == 1 ? "" : "es")",
                          systemImage: collapsed.contains(agent.id) ? "chevron.right" : "chevron.down")
                        .font(WorkspaceType.text(11)).padding(.vertical, 3)
                }.buttonStyle(.plain).padding(.leading, 80)
                    .accessibilityLabel("\(collapsed.contains(agent.id) ? "Show" : "Hide") descendants of \(agent.name)")
            }
        }
    }
}

private struct HierarchyAnchors: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct HierarchyNode: View {
    let name: String
    let task: String
    let status: String
    let presence: AgentPresence
    let accent: Color
    var lead = false
    var parent: String?

    var body: some View {
        HStack(spacing: 12) {
            AgentIllustration(presence: presence, accent: accent, isLead: lead)
                .frame(width: lead ? 96 : 64, height: lead ? 72 : 48).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(WorkspaceType.text(lead ? 17 : 14, strong: true)).lineLimit(2).help(name)
                Text(task).font(WorkspaceType.text(12)).lineLimit(1).help(task)
                if let parent {
                    Text("Parent: \(parent)").font(WorkspaceType.text(11)).foregroundStyle(Palette.muted)
                        .lineLimit(1).help("Parent: \(parent)")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Label(status, systemImage: presence.symbol).font(WorkspaceType.text(12))
                .foregroundStyle(presence == .error ? Palette.error : Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Image(systemName: "bubble.left").font(.system(size: 12)).foregroundStyle(Palette.muted)
                .opacity(presence == .stopped ? 0 : 1).accessibilityHidden(true)
        }.padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}
