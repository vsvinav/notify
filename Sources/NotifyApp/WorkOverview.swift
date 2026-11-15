import SwiftUI
import AppKit
import NotifyCore

func reorderedSessionIDs(_ ids: [String], moving source: String, over target: String) -> [String]? {
    guard source != target, let from = ids.firstIndex(of: source), let to = ids.firstIndex(of: target) else { return nil }
    var result = ids
    result.remove(at: from)
    result.insert(source, at: to)
    return result
}

func sessionMoveTarget(_ id: String, in group: [String], offset: Int) -> String? {
    guard offset == -1 || offset == 1, let index = group.firstIndex(of: id),
          group.indices.contains(index + offset) else { return nil }
    return group[index + offset]
}

struct WorkOverview: View {
    @ObservedObject var store: Store
    @State private var filter = "Live"
    @State private var search = ""
    @State private var order: [String] = []
    @State private var showDisconnected = false
    @State private var dropTargetID: String?
    @State private var showIdleCleanup = false
    private var connected: [SessionRecord] { visible.filter { $0.connected && !$0.needsSetup } }
    private var disconnected: [SessionRecord] { visible.filter { !$0.connected || $0.needsSetup } }
    private var visible: [SessionRecord] {
        let records = store.sessions.filter { session in
            (filter == "Saved" ? session.isSaved : !session.isSaved) &&
            (!store.waitingOnly || (session.connected && !session.requests.isEmpty)) &&
            (search.isEmpty || "\(session.name) \(session.cwd) \(session.summary)".localizedCaseInsensitiveContains(search))
        }
        return records.sorted {
            let a = order.firstIndex(of: $0.id) ?? Int.max
            let b = order.firstIndex(of: $1.id) ?? Int.max
            return a == b ? $0.id < $1.id : a < b
        }
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Sessions").font(WorkspaceType.text(23, strong: true))
                    Spacer()
                    Button { store.settingsVisible = true } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Notify settings")
                }
                Picker("Session source", selection: $filter) {
                    Text("Live").tag("Live")
                    Text("Saved").tag("Saved")
                }.pickerStyle(.segmented).labelsHidden()
                TextField("Search sessions", text: $search,
                          prompt: Text("Search sessions").foregroundColor(Palette.muted))
                    .textFieldStyle(.roundedBorder)
                if filter == "Live" {
                    Toggle("Needs you only (\(store.waitingCount))", isOn: $store.waitingOnly)
                        .toggleStyle(.checkbox).font(.system(size: 12))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if visible.isEmpty {
                            Text(!search.isEmpty ? "No matching sessions." : store.waitingOnly ? "Nothing waiting on you." : "No sessions in this view.")
                                .font(.system(size: 13)).foregroundStyle(Palette.muted).padding(.vertical, 12)
                        } else if filter == "Saved" {
                            sessionGroup("Saved chats", records: visible)
                        } else {
                            if !connected.isEmpty {
                                Text("Connected · \(connected.count)").font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Palette.muted).accessibilityAddTraits(.isHeader)
                                let waiting = connected.filter { !$0.requests.isEmpty }
                                if !waiting.isEmpty { sessionGroup("Needs you", records: waiting) }
                                let monitoring = connected.filter { $0.requests.isEmpty }
                                if !monitoring.isEmpty { sessionGroup("Monitoring", records: monitoring) }
                            }
                            if connected.isEmpty {
                                Text("No connected sessions yet. Select a terminal below to see how to connect it.")
                                    .font(.system(size: 13)).foregroundStyle(Palette.muted)
                            }
                        }
                    }
                }.scrollIndicators(.visible)
                    .frame(maxHeight: filter == "Live" && connected.isEmpty && !disconnected.isEmpty ? 65 : .infinity)
                if filter == "Live", !disconnected.isEmpty {
                    Divider()
                    DisclosureGroup("Not connected · \(disconnected.count)", isExpanded: $showDisconnected) {
                        ScrollView { sessionRows(disconnected).padding(.top, 8) }
                            .frame(maxHeight: connected.isEmpty ? .infinity : 190)
                    }.font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted)
                }
                Button { store.showSetup() } label: {
                    Label("Connect agents", systemImage: "plus")
                }.buttonStyle(.borderless).font(WorkspaceType.text(13, strong: true))
                Button { showIdleCleanup = true } label: {
                    Label("Stop idle >10 min", systemImage: "stop.circle")
                }.buttonStyle(.borderless).font(WorkspaceType.text(13, strong: true))
                    .help("Review cleanup across all connected sessions.")
            }.padding(18).frame(width: 232).background(Palette.sidebar)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                if let selected = store.selected, visible.contains(where: { $0.id == selected.id }) {
                    WorkDetail(store: store, session: selected).id(selected.id)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(!search.isEmpty ? "No matching sessions." : store.waitingOnly ? "You're all caught up." : "Your work starts in the terminal.")
                            .font(.system(size: 26, weight: .semibold))
                        Text(!search.isEmpty ? "Try a session name or project folder, or clear your search." :
                                store.waitingOnly ? "Connected agents will appear here when they need an answer." :
                                "Connect a running Copilot terminal, or start an agent with the Notify launcher.")
                            .font(.system(size: 13)).foregroundStyle(Palette.muted)
                        if !search.isEmpty || store.waitingOnly {
                            Button("Show all sessions") { search = ""; store.waitingOnly = false }
                        } else {
                            if filter == "Saved" {
                                Text("Saved Copilot chats appear here after discovery.")
                                    .font(.system(size: 13)).foregroundStyle(Palette.muted)
                            } else {
                                Button("Connect agents") { store.showSetup() }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.surface)
        }
        .sheet(isPresented: $showIdleCleanup) { IdleSubagentCleanupView(store: store) }
        .onAppear {
            updateOrder()
            showDisconnected = connected.isEmpty || store.selected?.connected == false
            store.reconcileSelection(in: visible)
        }
        .onChange(of: store.sessions.map { "\($0.id):\($0.sourceSessionID ?? "")" }.sorted()) { updateOrder() }
        .onChange(of: store.sessionOrder) { updateOrder() }
        .onChange(of: connected.isEmpty) { if connected.isEmpty { showDisconnected = true } }
        .onChange(of: visible.map { "\($0.id):\($0.connected):\($0.requests.count)" }) { store.reconcileSelection(in: visible) }
        .onChange(of: filter) { if filter == "Saved" { store.waitingOnly = false } }
        .onChange(of: store.selectedID) {
            guard store.selectionIsExplicit, let selected = store.selected else { return }
            if !visible.contains(where: { $0.id == selected.id }) {
                filter = selected.isSaved ? "Saved" : "Live"
                search = ""
                store.waitingOnly = false
            }
            if !selected.connected { showDisconnected = true }
        }
    }
    private func sessionGroup(_ title: String, records: [SessionRecord]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(WorkspaceType.text(13, strong: true))
                .foregroundStyle(title == "Needs you" ? Palette.accent : Palette.muted).accessibilityAddTraits(.isHeader)
            sessionRows(records)
        }
    }
    private func sessionRows(_ records: [SessionRecord]) -> some View {
        LazyVStack(spacing: 5) {
            ForEach(records) { session in
                Button { store.select(session.id) } label: {
                    WorkRow(store: store, session: session, isDropTarget: dropTargetID == session.id)
                }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(store.selectedID == session.id ? .isSelected : [])
                    .accessibilityHint("Drag to reorder within this group, or use the Move up and Move down actions.")
                    .draggable(session.id) {
                        Text(session.name).font(WorkspaceType.text(14, strong: true))
                            .padding(12).background(Palette.raised).foregroundStyle(Palette.ink)
                    }
                    .dropDestination(for: String.self) { ids, _ in
                        dropTargetID = nil
                        guard ids.count == 1, let source = ids.first else { return false }
                        return moveSession(source, over: session.id, within: records)
                    } isTargeted: { targeted in
                        if targeted { dropTargetID = session.id }
                        else if dropTargetID == session.id { dropTargetID = nil }
                    }
                    .accessibilityActions {
                        if let target = sessionMoveTarget(session.id, in: records.map(\.id), offset: -1) {
                            Button("Move up") { _ = moveSession(session.id, over: target, within: records) }
                        }
                        if let target = sessionMoveTarget(session.id, in: records.map(\.id), offset: 1) {
                            Button("Move down") { _ = moveSession(session.id, over: target, within: records) }
                        }
                    }
            }
        }
    }
    private func moveSession(_ source: String, over target: String, within group: [SessionRecord]) -> Bool {
        guard group.contains(where: { $0.id == source }), group.contains(where: { $0.id == target }),
              let updated = reorderedSessionIDs(order, moving: source, over: target) else { return false }
        order = updated
        store.rememberSessionOrder(order)
        return true
    }
    private func updateOrder() {
        let ids = Set(store.sessions.map(\.id))
        order.removeAll { !ids.contains($0) }
        order.append(contentsOf: store.sessions.filter { !order.contains($0.id) }.map(\.id))
        let stable = order
        func rank(_ id: String) -> Int {
            let key = store.registry.sessions[id]?.sourceSessionID ?? id
            return store.sessionOrder.firstIndex(of: key) ?? store.sessionOrder.firstIndex(of: id) ?? Int.max
        }
        order.sort {
            let a = rank($0), b = rank($1)
            return a == b ? (stable.firstIndex(of: $0) ?? 0) < (stable.firstIndex(of: $1) ?? 0) : a < b
        }
    }
}

private struct WorkRow: View {
    @ObservedObject var store: Store
    let session: SessionRecord
    let isDropTarget: Bool
    @State private var hovering = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
                AgentIllustration(presence: AgentPresence(session: session), accent: store.sessionColor(session), portrait: true)
                    .frame(width: 36, height: 36)
                    .background(store.sessionColor(session).opacity(0.18), in: Circle())
                    .clipShape(Circle()).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.name).font(WorkspaceType.text(14, strong: true)).lineLimit(2)
                    Text("\(agentName(session.agent)) · \(session.projectLabel)")
                        .font(WorkspaceType.text(11)).foregroundStyle(Palette.muted).lineLimit(1)
                    Text(session.needsSetup ? "Needs setup" : !session.connected ? "Disconnected" :
                            session.requests.first?.title ?? stateName(session.state))
                        .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted).lineLimit(2)
                    if session.connected, let team = session.team, team.error == nil {
                        Label("\(team.runningCount) running", systemImage: "person.2")
                            .font(WorkspaceType.text(10)).foregroundStyle(Palette.muted)
                            .help("Running subagents: \(team.runningCount)")
                    } else if session.connected {
                        Label("Team unavailable", systemImage: "person.2")
                            .font(WorkspaceType.text(10)).foregroundStyle(Palette.muted)
                    }
                    if store.automation.dangerous.contains(session.id) {
                        Label("Dangerous Auto-yes", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.error)
                    }
                }
                Spacer(minLength: 0)
                VStack(spacing: 12) {
                    Image(systemName: store.selectedID == session.id ? "chevron.right" : AgentPresence(session: session).symbol)
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.accent)
                        .accessibilityLabel(AgentPresence(session: session).title)
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(hovering || isDropTarget ? Palette.accent : Palette.muted)
                        .help("Drag to reorder within this group")
                        .accessibilityHidden(true)
                }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Palette.ink)
            .background(store.selectedID == session.id ? Palette.raised :
                            hovering || isDropTarget ? Palette.raised.opacity(0.5) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isDropTarget ? Palette.accent : .clear, lineWidth: 2)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .help("\(session.name)\n\(agentName(session.agent)) · \(session.cwd)\n\(session.workHeadline)\nDrag to reorder within this group.")
    }
}

private struct WorkDetail: View {
    @ObservedObject var store: Store
    let session: SessionRecord
    @State private var tab: String
    @State private var chatAgentID: String?
    @State private var showSubagentManagement = false
    init(store: Store, session: SessionRecord) {
        self.store = store
        self.session = session
        _tab = State(initialValue: session.connected && !session.needsSetup && !session.isSaved && session.requests.isEmpty ? "Chat" : "Decision")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                Circle().fill(store.sessionColor(session)).frame(width: 10, height: 10).padding(.top, 17)
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.name).font(WorkspaceType.text(34, strong: true)).lineLimit(2).textSelection(.enabled)
                    Text("\(agentName(session.agent)) · \(session.projectLabel)")
                        .font(WorkspaceType.text(13)).foregroundStyle(Palette.muted)
                    if session.agent == "claude" {
                        Text("Subagent creation, model selection and removal unavailable")
                            .font(WorkspaceType.text(11)).foregroundStyle(Palette.muted)
                    }
                }
                Spacer(minLength: 12)
                if session.agent == "copilot" {
                    Button { showSubagentManagement = true } label: {
                        Label("Add subagent", systemImage: "plus")
                    }.padding(.top, 10).help("Create a helper or remove ended helpers from this session.")
                }
                TerminalSessionButton(store: store, session: session).padding(.top, 10)
            }
            if store.automation.dangerous.contains(session.id) {
                DangerousAutoYesWarning(store: store, sessionID: session.id)
            }
            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 16) {
                        Picker("Session view", selection: $tab) {
                            Text("Chat").tag("Chat")
                            Text(session.requests.isEmpty ? "Overview" : "Decision").tag("Decision")
                            Text("Settings").tag("Session")
                            Text("Hierarchy").tag("Hierarchy")
                        }.pickerStyle(.segmented).labelsHidden()
                        if tab != "Decision", session.connected, !session.requests.isEmpty {
                            HStack {
                                Label("Decision waiting", systemImage: "questionmark.circle").font(WorkspaceType.text(13, strong: true))
                                Spacer()
                                Button("Review") { tab = "Decision" }
                            }.padding(10).background(Palette.raised, in: RoundedRectangle(cornerRadius: 8))
                        }
                        if let error = store.sessionErrors[session.id] {
                            Text(error).font(WorkspaceType.text(13)).foregroundStyle(Palette.amber).textSelection(.enabled)
                        }
                        content
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .sheet(isPresented: $showSubagentManagement) {
                            SubagentManagementView(store: store, sessionID: session.id)
                        }
                    if tab != "Hierarchy" {
                    Divider()
                    VStack(alignment: .leading, spacing: 16) {
                        SubagentTeamView(store: store, session: session, compact: tab != "Chat", selectedAgentID: chatAgentID) {
                            chatAgentID = $0
                            tab = "Chat"
                        }
                        if tab != "Chat" {
                            Divider()
                            Label(session.connected && !session.needsSetup && !session.isSaved ? "Live activity" : "Recent activity",
                                  systemImage: "text.alignleft")
                                .font(WorkspaceType.text(16, strong: true))
                            SessionTimeline(store: store, showsHeader: false)
                        }
                    }.frame(width: min(310, max(252, geometry.size.width * 0.36)),
                            height: geometry.size.height, alignment: .topLeading)
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    @ViewBuilder private var content: some View {
            if tab == "Chat" {
                AgentChatView(store: store, session: session, agentID: chatAgentID).id(chatAgentID)
            } else if tab == "Hierarchy" {
                AgentHierarchyView(store: store, session: session, selectedAgentID: chatAgentID) {
                    chatAgentID = $0
                    tab = "Chat"
                }
            } else if tab == "Session" {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(session.cwd).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                        SessionColorPicker(store: store, session: session)
                        SessionDescriptionView(store: store, session: session)
                        SessionAutoYesView(store: store, session: session, showsDangerWarning: false)
                        Toggle("Allow verified safe reads", isOn: Binding(get: { !store.mutedSessions.contains(session.id) }, set: {
                            if $0 { store.mutedSessions.remove(session.id) } else { store.mutedSessions.insert(session.id) }
                        })).disabled(!session.connected)
                        Text("The global safe-read setting must also be enabled. Session Auto-yes is separate from remembered terminal permissions.")
                            .font(.system(size: 13)).foregroundStyle(Palette.muted)
                        Button("Open project folder") { NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd)) }.disabled(session.cwd.isEmpty)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if session.needsSetup {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Connect this running terminal").font(.title2)
                        Text("This session is running, but Notify is not connected to its requests or activity.")
                        if session.agent == "claude" {
                            Button("Add hooks for Claude Code") { store.showSetup(.claude) }
                            Text("After adding hooks, wait until Claude is idle before reviewing and closing /hooks; opening it ends the current turn. Notify connects on its next hook event. Already-waiting prompts remain in the terminal.")
                                .foregroundStyle(Palette.muted)
                        } else {
                            Button("Set up Copilot connection") { store.showSetup(.copilot) }
                            Text("If experimental mode is already enabled, open /extensions manage in that terminal, enable notify, close the manager, then approve permission access. If Notify is missing, ask Copilot to reload extensions.")
                            Text("Do not enable experimental mode during active work: this Copilot version restarts its UI when the setting changes.")
                                .foregroundStyle(Palette.amber)
                        }
                    }.font(.system(size: 14)).textSelection(.enabled)
                }
            } else if session.isSaved || !session.connected {
                VStack(alignment: .leading, spacing: 18) {
                    Text(session.isSaved ? "Pick up this work in iTerm2." : "This agent is disconnected.").font(.title2)
                    SessionDescriptionView(store: store, session: session)
                    Text(session.isSaved
                         ? "Resume opens the saved session in iTerm2 with its original CLI and permissions. Notify connects once the hooks or extension load."
                         : "Previous activity is available, but controls stay disabled until the agent reconnects.")
                        .font(.system(size: 14)).foregroundStyle(Palette.muted)
                    Spacer()
                }
            } else if let request = store.activeRequest {
                if session.requests.count > 1 {
                    Picker("Pending request", selection: Binding(get: { request.id }, set: { store.selectedRequestID = $0 })) {
                        ForEach(session.requests) { Text($0.title).tag($0.id) }
                    }
                }
                RequestEditor(store: store, session: session, request: request).id(request.id)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Nothing waiting on you.").font(WorkspaceType.text(25, strong: true))
                    Text(session.workHeadline).font(WorkspaceType.text(15, strong: true)).textSelection(.enabled)
                    Text(session.baseState == "ready" ? "The agent is idle. This does not confirm that its task or tests succeeded." :
                            "Live activity is beside you. Use Chat to give the agent direction.")
                        .font(.system(size: 14)).foregroundStyle(Palette.muted)
                    Button("Send instruction") { chatAgentID = nil; tab = "Chat" }
                    Spacer()
                }
            }
    }
}
