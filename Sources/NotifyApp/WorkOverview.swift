import SwiftUI
import AppKit
import NotifyCore

struct WorkOverview: View {
    @ObservedObject var store: Store
    @State private var filter = "Live"
    @State private var search = ""
    @State private var order: [String] = []
    @State private var showDisconnected = false
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
                    Text("Sessions").font(.system(size: 22, weight: .semibold))
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
            }.padding(20).frame(width: 272).background(Palette.sidebar)
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
                            Text(filter == "Saved" ? "Saved Copilot chats appear here after discovery." : "~/.local/bin/notify setup-copilot")
                                .font(.system(size: 14, design: .monospaced)).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }.padding(26).frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.surface)
        }
        .onAppear {
            updateOrder()
            showDisconnected = connected.isEmpty || store.selected?.connected == false
            store.reconcileSelection(in: visible)
        }
        .onChange(of: store.sessions.map(\.id).sorted()) { updateOrder() }
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
            Text(title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(title == "Needs you" ? Palette.accent : Palette.muted).accessibilityAddTraits(.isHeader)
            sessionRows(records)
        }
    }
    private func sessionRows(_ records: [SessionRecord]) -> some View {
        LazyVStack(spacing: 5) {
            ForEach(records) { session in
                Button { store.select(session.id) } label: { WorkRow(store: store, session: session) }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(store.selectedID == session.id ? .isSelected : [])
            }
        }
    }
    private func updateOrder() {
        let ids = Set(store.sessions.map(\.id))
        order.removeAll { !ids.contains($0) }
        order.append(contentsOf: store.sessions.filter { !order.contains($0.id) }.map(\.id))
    }
}

private struct WorkRow: View {
    @ObservedObject var store: Store
    let session: SessionRecord
    var body: some View {
        HStack(spacing: 11) {
                Circle().fill(store.sessionColor(session)).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Text("\(agentName(session.agent)) · \(session.projectLabel)")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                    Text(session.needsSetup ? "Needs setup" : !session.connected ? "Disconnected" :
                            session.requests.first?.title ?? stateName(session.state))
                        .font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(2)
                }
                Spacer(minLength: 0)
                if store.selectedID == session.id {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.accent)
                }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Palette.ink)
            .background(store.selectedID == session.id ? Palette.raised : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .help("\(session.name)\n\(agentName(session.agent)) · \(session.cwd)\n\(session.workHeadline)")
    }
}

private struct WorkDetail: View {
    @ObservedObject var store: Store
    let session: SessionRecord
    @State private var tab = "Decision"
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                Circle().fill(store.sessionColor(session)).frame(width: 10, height: 10).padding(.top, 8)
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.name).font(.system(size: 21, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                    Text("\(agentName(session.agent)) · \(session.projectLabel) · \(session.needsSetup ? "Needs setup" : stateName(session.state))")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                TerminalSessionButton(store: store, session: session)
                Button("Send instruction") { store.showSteering(session.id) }.disabled(!session.connected || !session.canSteer)
                Spacer()
            }.controlSize(.regular)
            Picker("Session view", selection: $tab) {
                Text("Decision").tag("Decision")
                Text("Activity").tag("Activity")
                Text("Session settings").tag("Session")
            }.pickerStyle(.segmented).labelsHidden()
            if tab != "Decision", session.connected, !session.requests.isEmpty {
                HStack {
                    Label("Decision waiting", systemImage: "questionmark.circle").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Review") { tab = "Decision" }
                }.padding(12).background(Palette.raised, in: RoundedRectangle(cornerRadius: 8))
            }
            if let error = store.sessionErrors[session.id] {
                Text(error).font(.system(size: 13)).foregroundStyle(Palette.amber).textSelection(.enabled)
            }
            if tab == "Activity" {
                SessionTimeline(store: store, showsHeader: false)
            } else if tab == "Session" {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(session.cwd).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                        SessionColorPicker(store: store, session: session)
                        SessionDescriptionView(store: store, session: session)
                        SessionAutoYesView(store: store, session: session)
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
                        Text("If experimental mode is already enabled, open /extensions manage in that terminal, enable notify, close the manager, then approve permission access. If the extension is missing, ask Copilot to reload extensions.")
                        Text("Do not enable experimental mode during active work: this Copilot version restarts its UI when the setting changes.")
                            .foregroundStyle(Palette.amber)
                    }.font(.system(size: 14)).textSelection(.enabled)
                }
            } else if session.isSaved || !session.connected {
                VStack(alignment: .leading, spacing: 18) {
                    Text(session.isSaved ? "Pick up this work in iTerm2." : "This agent is disconnected.").font(.title2)
                    SessionDescriptionView(store: store, session: session)
                    Text(session.isSaved ? "Resume keeps the original CLI and its saved permission settings. Notify never grants extension access automatically." :
                            "Previous activity is available, but controls stay disabled until the agent reconnects.")
                        .font(.system(size: 14)).foregroundStyle(Palette.muted)
                    Spacer()
                }
            } else if let request = store.activeRequest {
                if session.requests.count > 1 {
                    Picker("Pending request", selection: Binding(get: { request.id }, set: { store.selectedRequestID = $0 })) {
                        ForEach(session.requests) { Text($0.title).tag($0.id) }
                    }
                }
                RequestEditor(store: store, session: session, request: request, wide: true).id(request.id)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Nothing waiting on you.").font(.system(size: 25, weight: .semibold))
                    Text(session.workHeadline).font(.system(size: 15, weight: .medium)).textSelection(.enabled)
                    Text(session.baseState == "ready" ? "The agent is idle. This does not confirm that its task or tests succeeded." :
                            "The agent is connected. Its reported progress is in Activity.")
                        .font(.system(size: 14)).foregroundStyle(Palette.muted)
                    Button("View activity") { tab = "Activity" }
                    Spacer()
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
