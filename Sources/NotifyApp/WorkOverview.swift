import SwiftUI
import AppKit
import NotifyCore

struct WorkOverview: View {
    @ObservedObject var store: Store
    @State private var filter = "Live"
    @State private var search = ""
    @State private var order: [String] = []
    private var visible: [SessionRecord] {
        let records = store.sessions.filter { session in
            (filter == "Saved" ? session.isSaved : !session.isSaved) &&
            (!store.waitingOnly || !session.requests.isEmpty) &&
            (search.isEmpty || "\(session.name) \(session.cwd) \(session.summary)".localizedCaseInsensitiveContains(search))
        }
        return records.sorted {
            let a = order.firstIndex(of: $0.id) ?? Int.max
            let b = order.firstIndex(of: $1.id) ?? Int.max
            return a == b ? $0.id < $1.id : a < b
        }
    }
    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Notify").font(.system(size: 19, weight: .medium))
                    Spacer()
                    ForEach(["Live", "Saved"], id: \.self) { value in
                        Button(value) { filter = value }.buttonStyle(.plain)
                            .foregroundStyle(filter == value ? Palette.accent : Palette.muted)
                            .accessibilityAddTraits(filter == value ? .isSelected : [])
                    }
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                        TextField("Find a session", text: $search).textFieldStyle(.plain)
                    }.frame(width: 170).padding(.horizontal, 12)
                    Button("Settings") { store.settingsVisible = true }
                        .buttonStyle(.plain).foregroundStyle(Palette.muted)
                        .accessibilityLabel("Notify settings")
                }.font(.system(size: 12))
                HStack(alignment: .firstTextBaseline) {
                    Text(filter == "Saved" ? "Pick up where you left off." : "Your sessions, at a glance.")
                        .font(.system(size: 17, weight: .regular))
                    Spacer()
                    Button("\(store.waitingCount) need you") { store.waitingOnly.toggle() }
                        .buttonStyle(.plain).foregroundStyle(store.waitingOnly ? Palette.ink : Palette.accent)
                        .accessibilityLabel(store.waitingOnly ? "Show all sessions" : "Show sessions needing you")
                        .font(.system(size: 12))
                }.padding(.top, 4)
                ScrollView {
                    VStack(alignment: .leading, spacing: 19) {
                        if visible.isEmpty {
                            Text(search.isEmpty ? "No sessions in this view. Connect an agent or browse saved chats." : "No matching tasks or projects.")
                                .font(.system(size: 13)).foregroundStyle(Palette.muted).padding(.vertical, 12)
                        } else if filter == "Saved" {
                            sessionGroup("Saved chats", records: visible)
                        } else {
                            let connected = visible.filter { $0.connected && !$0.needsSetup }
                            let disconnected = visible.filter { !$0.connected || $0.needsSetup }
                            sessionGroup("Connected", records: connected)
                            if !disconnected.isEmpty { sessionGroup("Not connected", records: disconnected) }
                        }
                    }
                }.frame(height: min(260, max(120, 120 + (geometry.size.height - 620) * 0.65)))
                    .scrollIndicators(.visible)
                Divider().padding(.vertical, 3)
                if let selected = store.selected {
                    WorkDetail(store: store, session: selected).id(selected.id)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Stay with your work.").font(.system(size: 24, weight: .regular))
                        Text("Select a session to review its activity, answer a question, or open its terminal.")
                            .font(.system(size: 13)).foregroundStyle(Palette.muted)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }.padding(.horizontal, 30).padding(.vertical, 22).background(Palette.surface)
        }
        .onAppear { updateOrder() }
        .onChange(of: store.sessions.map(\.id).sorted()) { updateOrder() }
        .onChange(of: filter) { if filter == "Saved" { store.waitingOnly = false } }
    }
    private func sessionGroup(_ title: String, records: [SessionRecord]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(title) · \(records.count)").font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted).accessibilityAddTraits(.isHeader)
            if records.isEmpty {
                Text("No connected sessions yet.").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 9) {
                ForEach(records) { session in
                    Button { store.select(session.id) } label: { WorkRow(store: store, session: session) }
                        .buttonStyle(.plain)
                }
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
                Circle().fill(store.sessionColor(session))
                    .frame(width: store.selectedID == session.id ? 10 : 7, height: store.selectedID == session.id ? 10 : 7)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.name).font(.system(size: 13, weight: .regular)).lineLimit(1)
                    Text("\(session.projectLabel) · \(session.needsSetup ? "Needs setup" : stateName(session.state))")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
        }.padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(store.selectedID == session.id ? Palette.accent : Palette.ink)
            .contentShape(Rectangle())
            .help("\(session.name)\n\(agentName(session.agent)) · \(session.cwd)\n\(session.workHeadline)")
    }
}

private struct WorkDetail: View {
    @ObservedObject var store: Store
    let session: SessionRecord
    @State private var tab = "Decision"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Circle().fill(store.sessionColor(session)).frame(width: 7, height: 7).padding(.top, 8)
                Text("\(session.name) · \(agentName(session.agent))")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.accent).textSelection(.enabled)
                Spacer()
                TerminalSessionButton(store: store, session: session).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            HStack(spacing: 20) {
                ForEach(["Decision", "Activity", "Session"], id: \.self) { value in
                    Button(value == "Decision" && session.requests.isEmpty ? "Overview" : value) { tab = value }
                        .buttonStyle(.plain).foregroundStyle(tab == value ? Palette.ink : Palette.muted)
                        .accessibilityAddTraits(tab == value ? .isSelected : [])
                }
                Spacer()
                Button("Steer") { store.showSteering(session.id) }.disabled(!session.connected || !session.canSteer)
                    .buttonStyle(.plain).foregroundStyle(Palette.muted)
            }.font(.system(size: 12))
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
                    Text(session.workHeadline).font(.system(size: 19, weight: .medium)).textSelection(.enabled)
                    Text(session.baseState == "ready" ? "The agent is idle. This does not confirm that its task or tests succeeded." :
                            "No decision is waiting on you. Activity below is what the agent has actually reported.")
                        .font(.system(size: 14)).foregroundStyle(Palette.muted)
                    SessionTimeline(store: store, showsHeader: false)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
