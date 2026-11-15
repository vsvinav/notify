import SwiftUI
import NotifyCore

struct AgentHierarchyView: View {
    @ObservedObject var store: Store
    let session: SessionRecord
    var selectedAgentID: String?
    let selectAgent: (String?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let hierarchy = SubagentHierarchy(agents: session.team?.agents ?? [])
        let accent = store.sessionColor(session)
        let current = session.connected && session.team?.error == nil
        VStack(alignment: .leading, spacing: 10) {
            Text("Agent hierarchy").font(WorkspaceType.text(25, strong: true))
            Text("Select an agent to open its chat. Fold branches to focus on one team.")
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
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    VStack(spacing: 36) {
                        VStack(spacing: 32) {
                            Button { selectAgent(nil) } label: {
                                HierarchyNode(name: "Main agent", task: session.name, status: AgentPresence(session: session).title,
                                              presence: AgentPresence(session: session), accent: accent, lead: true)
                            }.buttonStyle(AgentSelectionStyle(selected: selectedAgentID == nil, accent: accent))
                                .accessibilityLabel("Chat with main agent")
                                .anchorPreference(key: HierarchyAnchors.self, value: .bounds) { ["root": $0] }
                            HStack(alignment: .top, spacing: 24) {
                                ForEach(hierarchy.roots) { agent in
                                    branch(agent, hierarchy: hierarchy, current: current, accent: accent)
                                }
                            }
                        }
                        if !hierarchy.unlinked.isEmpty {
                            VStack(spacing: 16) {
                                Text("Parent not reported or outside this view")
                                    .font(WorkspaceType.text(15, strong: true))
                                Text("No connection is drawn unless the reported relationship can be shown safely.")
                                    .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
                                HStack(alignment: .top, spacing: 24) {
                                    ForEach(hierarchy.unlinked) { agent in
                                        branch(agent, hierarchy: hierarchy, current: current, accent: accent)
                                    }
                                }
                            }
                        }
                    }.padding(24).frame(minWidth: geometry.size.width, alignment: .top)
                        .backgroundPreferenceValue(HierarchyAnchors.self) { anchors in
                            GeometryReader { positions in
                                Path { path in
                                    let edges = hierarchy.roots.map { ("root", "agent:\($0.id)") } +
                                        hierarchy.children.flatMap { parent, children in
                                            children.map { ("agent:\(parent)", "agent:\($0.id)") }
                                        }
                                    for (parent, child) in edges {
                                        guard let a = anchors[parent], let b = anchors[child] else { continue }
                                        let start = positions[a], end = positions[b]
                                        let midpoint = (start.maxY + end.minY) / 2
                                        path.addLines([CGPoint(x: start.midX, y: start.maxY),
                                                       CGPoint(x: start.midX, y: midpoint),
                                                       CGPoint(x: end.midX, y: midpoint),
                                                       CGPoint(x: end.midX, y: end.minY)])
                                    }
                                }.stroke(Palette.line, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                                    .accessibilityHidden(true)
                            }
                        }
                        .animation(reduceMotion || !store.centerVisible ? nil : .easeOut(duration: 0.2), value: session.team?.agents)
                }.scrollIndicators(.visible)
            }
        }.foregroundStyle(Palette.ink)
    }

    private func branch(_ agent: SubagentRecord, hierarchy: SubagentHierarchy, current: Bool, accent: Color) -> some View {
        HierarchyBranch(agent: agent, hierarchy: hierarchy, current: current, accent: accent,
                        selectedAgentID: selectedAgentID, animate: store.centerVisible && !reduceMotion, selectAgent: selectAgent)
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

    var body: some View {
        VStack(spacing: 5) {
            AgentIllustration(presence: presence, accent: accent, isLead: lead)
                .frame(width: lead ? 180 : 110, height: lead ? 136 : 83).accessibilityHidden(true)
            Text(name).font(WorkspaceType.text(lead ? 17 : 14, strong: true)).lineLimit(2)
            Label(status, systemImage: presence.symbol).font(WorkspaceType.text(12))
                .foregroundStyle(presence == .error ? Palette.error : Palette.muted)
            Text(task).font(WorkspaceType.text(12)).lineLimit(3).help(task)
        }.padding(10).frame(width: lead ? 240 : 180)
            .contentShape(Rectangle())
    }
}

private struct HierarchyBranch: View {
    let agent: SubagentRecord
    let hierarchy: SubagentHierarchy
    let current: Bool
    let accent: Color
    let selectedAgentID: String?
    let animate: Bool
    let selectAgent: (String?) -> Void
    @State private var collapsed = false

    var body: some View {
        let children = hierarchy.children[agent.id] ?? []
        let state: AgentPresence = agent.status == .cancelled ? .stopped : !current ? .disconnected :
            agent.status == .running ? .working : agent.status == .idle ? .resting :
            agent.status == .failed ? .error : .finished
        VStack(spacing: 0) {
            Button { selectAgent(agent.id) } label: {
                HierarchyNode(name: agent.name, task: agent.task,
                              status: current ? (agent.status == .cancelled ? "Stopped" : agent.status.rawValue.capitalized) :
                                "Last seen: \(agent.status.rawValue)", presence: state, accent: accent)
            }.buttonStyle(AgentSelectionStyle(selected: selectedAgentID == agent.id, accent: accent))
                .disabled(agent.status == .cancelled)
                .accessibilityLabel(agent.status == .cancelled ? "\(agent.name), stopped" : "Chat with \(agent.name)")
                .anchorPreference(key: HierarchyAnchors.self, value: .bounds) { ["agent:\(agent.id)": $0] }
            if !children.isEmpty {
                Button {
                    withAnimation(animate ? .easeOut(duration: 0.2) : nil) { collapsed.toggle() }
                } label: {
                    Label("\(collapsed ? "Show" : "Hide") \(children.count) branch\(children.count == 1 ? "" : "es")",
                          systemImage: collapsed ? "chevron.right" : "chevron.down")
                        .font(WorkspaceType.text(11)).padding(6).background(Palette.surface)
                }.buttonStyle(.plain).accessibilityLabel("\(collapsed ? "Show" : "Hide") descendants of \(agent.name)")
                if !collapsed {
                    HStack(alignment: .top, spacing: 24) {
                        ForEach(children) { child in
                            HierarchyBranch(agent: child, hierarchy: hierarchy, current: current, accent: accent,
                                            selectedAgentID: selectedAgentID, animate: animate, selectAgent: selectAgent)
                        }
                    }.padding(.top, 26).transition(.opacity)
                }
            }
        }
    }
}
