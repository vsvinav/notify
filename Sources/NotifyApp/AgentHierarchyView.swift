import SwiftUI
import NotifyCore

struct AgentHierarchyView: View {
    @ObservedObject var store: Store
    let session: SessionRecord
    var selectedAgentID: String?
    let selectAgent: (String?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chartSize = CGSize.zero
    @State private var zoom: CGFloat?
    @State private var showInactive = false
    @State private var showIdle = false

    private var animate: Bool { store.centerVisible && !reduceMotion }

    var body: some View {
        let hierarchy = SubagentHierarchy(agents: session.team?.agents ?? [], hidingInactive: true, hidingIdle: !showIdle)
        let accent = store.sessionColor(session)
        let current = session.connected && session.team?.error == nil
        VStack(alignment: .leading, spacing: 8) {
            Text("Agent hierarchy").font(WorkspaceType.text(25, strong: true))
            Text("Running agents at a glance. Expand idle subagents to see the rest of your team.")
                .font(WorkspaceType.text(13)).foregroundStyle(Palette.muted)
            if let team = session.team {
                Text(team.error ?? (current ? "\(team.runningCount) running · \(team.idleCount) ready for follow-up" :
                    "Last reported hierarchy. Reconnect for current status."))
                    .font(WorkspaceType.text(12)).foregroundStyle(team.error == nil ? Palette.muted : Palette.amber)
                if team.truncated {
                    Text("Showing up to 100 agents; some parents and inactive agents may be outside this view.")
                        .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
                }
            } else {
                Text("This connection has not reported a team yet.")
                    .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
            }
            GeometryReader { viewport in
                let fit = min(1, min(max(1, viewport.size.width - 8) / max(1, chartSize.width),
                                     max(1, viewport.size.height - 44) / max(1, chartSize.height)))
                let scale = zoom ?? fit
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Text("\(Int((scale * 100).rounded()))%").monospacedDigit().foregroundStyle(Palette.muted)
                        Spacer()
                        if showIdle && !hierarchy.idle.isEmpty {
                            Button("Hide idle") {
                                withAnimation(animate ? .easeOut(duration: 0.2) : nil) {
                                    showIdle = false
                                    zoom = nil
                                }
                            }.help("Collapse idle subagents back into one tile.")
                        }
                        Button { zoom = max(0.05, scale / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                            .accessibilityLabel("Zoom out")
                        Button { zoom = min(2, scale * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                            .accessibilityLabel("Zoom in")
                        Button("100%") { zoom = 1 }.help("Show readable actual-size agents; scroll to move around the chart.")
                        Button("Fit") { zoom = nil }.help("Fit the whole active org chart in the available space.")
                    }.font(WorkspaceType.text(12)).controlSize(.small).frame(height: 28)
                    ScrollView([.horizontal, .vertical]) {
                        chart(hierarchy, current: current, accent: accent)
                            .fixedSize()
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: HierarchySize.self, value: geometry.size)
                            })
                            .scaleEffect(scale, anchor: .topLeading)
                            .frame(width: chartSize == .zero ? nil : chartSize.width * scale,
                                   height: chartSize == .zero ? nil : chartSize.height * scale, alignment: .topLeading)
                            .padding(4)
                            .frame(minWidth: viewport.size.width, minHeight: max(1, viewport.size.height - 36), alignment: .top)
                    }.scrollIndicators(.visible)
                        .onPreferenceChange(HierarchySize.self) { if chartSize != $0 { chartSize = $0 } }
                }
            }
            if !hierarchy.hidden.isEmpty { inactiveBlock(hierarchy.hidden, accent: accent) }
        }.foregroundStyle(Palette.ink)
    }

    private func chart(_ hierarchy: SubagentHierarchy, current: Bool, accent: Color) -> some View {
        VStack(spacing: 28) {
            VStack(spacing: 28) {
                Button { selectAgent(nil) } label: {
                    HierarchyNode(name: "Main agent", task: session.name, status: AgentPresence(session: session).title,
                                  presence: AgentPresence(session: session), accent: accent, lead: true)
                }.buttonStyle(AgentSelectionStyle(selected: selectedAgentID == nil, accent: accent))
                    .accessibilityLabel("Chat with main agent")
                    .anchorPreference(key: HierarchyAnchors.self, value: .bounds) { ["root": $0] }
                if !hierarchy.roots.isEmpty || (!showIdle && !hierarchy.idle.isEmpty) {
                    HStack(alignment: .top, spacing: 24) {
                        ForEach(hierarchy.roots) { agent in
                            branch(agent, hierarchy: hierarchy, current: current, accent: accent)
                        }
                        if !showIdle && !hierarchy.idle.isEmpty {
                            Button {
                                withAnimation(animate ? .easeOut(duration: 0.2) : nil) { showIdle = true }
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: "person.3")
                                        .font(.system(size: 28)).foregroundStyle(accent).frame(height: 48)
                                    Text("+\(hierarchy.idle.count) idle subagent\(hierarchy.idle.count == 1 ? "" : "s")")
                                        .font(WorkspaceType.text(14, strong: true))
                                        .lineLimit(2, reservesSpace: true).multilineTextAlignment(.center)
                                    Label("Expand", systemImage: "chevron.down")
                                        .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
                                }.padding(8).frame(width: 148).contentShape(Rectangle())
                            }.buttonStyle(AgentSelectionStyle(selected: false, accent: accent))
                                .help("Grouped by status. Expand to see each helper and its reported parent relationship.")
                                .anchorPreference(key: HierarchyAnchors.self, value: .bounds) { ["idle-group": $0] }
                        }
                    }
                }
            }
            if !hierarchy.unlinked.isEmpty {
                VStack(spacing: 12) {
                    Text("Parent hidden, not reported or outside this view")
                        .font(WorkspaceType.text(13, strong: true)).foregroundStyle(Palette.muted)
                    HStack(alignment: .top, spacing: 24) {
                        ForEach(hierarchy.unlinked) { agent in
                            VStack(spacing: 6) {
                                if let id = agent.parentAgentID,
                                   let parent = session.team?.agents.first(where: { $0.id == id }) {
                                    Text("Parent: \(parent.name)").font(WorkspaceType.text(11))
                                        .lineLimit(2).frame(width: 148).help("Parent: \(parent.name)")
                                }
                                branch(agent, hierarchy: hierarchy, current: current, accent: accent)
                            }
                        }
                    }
                }
            }
        }.padding(12)
            .backgroundPreferenceValue(HierarchyAnchors.self) { anchors in
                GeometryReader { positions in
                    Path { path in
                        var edges = hierarchy.roots.map { ("root", "agent:\($0.id)") } +
                            hierarchy.children.flatMap { parent, children in
                                children.map { ("agent:\(parent)", "agent:\($0.id)") }
                            }
                        if !hierarchy.idle.isEmpty && hierarchy.idle.allSatisfy({ $0.parentKnown == true && $0.parentAgentID == nil }) {
                            edges.append(("root", "idle-group"))
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
            .animation(animate ? .easeOut(duration: 0.2) : nil, value: session.team?.agents)
    }

    private func branch(_ agent: SubagentRecord, hierarchy: SubagentHierarchy, current: Bool, accent: Color) -> some View {
        HierarchyBranch(agent: agent, hierarchy: hierarchy, current: current, accent: accent,
                        selectedAgentID: selectedAgentID, animate: animate, selectAgent: selectAgent)
    }

    private func inactiveBlock(_ agents: [SubagentRecord], accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(animate ? .easeOut(duration: 0.2) : nil) { showInactive.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Label(showInactive ? "Hide inactive agents" :
                            "+\(agents.count) hidden inactive agent\(agents.count == 1 ? "" : "s")",
                          systemImage: showInactive ? "chevron.down" : "chevron.right")
                    Spacer()
                    let failed = agents.filter { $0.status == .failed }.count
                    if failed > 0 { Text("\(failed) failed").foregroundStyle(Palette.error) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).font(WorkspaceType.text(13))
            if showInactive {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(agents) { agent in
                            Button { selectAgent(agent.id) } label: {
                                HStack(spacing: 10) {
                                    AgentIllustration(presence: agent.status == .cancelled ? .stopped :
                                                        agent.status == .failed ? .error : .finished, accent: accent)
                                        .frame(width: 40, height: 30).accessibilityHidden(true)
                                    Text(agent.name).font(WorkspaceType.text(13, strong: true)).lineLimit(2)
                                    Spacer()
                                    Text(agent.status == .cancelled ? "Stopped" : agent.status.rawValue.capitalized)
                                        .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
                                    if agent.status != .cancelled { Image(systemName: "bubble.left") }
                                }.frame(maxWidth: .infinity).contentShape(Rectangle()).help(agent.task)
                            }.buttonStyle(.plain).disabled(agent.status == .cancelled)
                                .accessibilityLabel(agent.status == .cancelled ? "\(agent.name), stopped" : "Chat with \(agent.name)")
                        }
                    }
                }.frame(height: min(144, CGFloat(agents.count) * 40)).scrollIndicators(.visible)
            }
        }.padding(12).background(Palette.background, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct HierarchySize: PreferenceKey {
    static var defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        value = CGSize(width: max(value.width, next.width), height: max(value.height, next.height))
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
        VStack(spacing: 4) {
            AgentIllustration(presence: presence, accent: accent, isLead: lead)
                .frame(width: lead ? 88 : 64, height: lead ? 66 : 48).accessibilityHidden(true)
            Text(name).font(WorkspaceType.text(lead ? 17 : 14, strong: true))
                .lineLimit(2, reservesSpace: true).multilineTextAlignment(.center)
            Label(status, systemImage: presence.symbol).font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
        }.padding(8).frame(width: lead ? 176 : 148).contentShape(Rectangle()).help("\(name)\n\(task)")
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
        VStack(spacing: 0) {
            Button { selectAgent(agent.id) } label: {
                HierarchyNode(name: agent.name, task: agent.task,
                              status: current ? agent.status.rawValue.capitalized : "Last seen: \(agent.status.rawValue)",
                              presence: !current ? .disconnected : agent.status == .running ? .working : .resting, accent: accent)
            }.buttonStyle(AgentSelectionStyle(selected: selectedAgentID == agent.id, accent: accent))
                .accessibilityLabel("Chat with \(agent.name)")
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
                    }.padding(.top, 22).transition(.opacity)
                }
            }
        }
    }
}
