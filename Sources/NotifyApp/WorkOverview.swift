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
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Notify").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Button { store.settingsVisible = true } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.plain).foregroundStyle(Palette.muted)
                        .help("Notify settings").accessibilityLabel("Notify settings")
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                    TextField("Find a session", text: $search).textFieldStyle(.plain)
                }.font(.system(size: 12)).padding(9).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                HStack(spacing: 16) {
                    ForEach(["Live", "Saved"], id: \.self) { value in
                        Button(value) { filter = value }.buttonStyle(.plain)
                            .foregroundStyle(filter == value ? Palette.ink : Palette.muted)
                            .accessibilityAddTraits(filter == value ? .isSelected : [])
                    }
                    Spacer(minLength: 0)
                    Button("\(store.waitingCount) need you") { store.waitingOnly.toggle() }
                        .buttonStyle(.plain).foregroundStyle(store.waitingOnly ? Palette.ink : Palette.accent)
                        .accessibilityLabel(store.waitingOnly ? "Show all sessions" : "Show sessions needing you")
                }
                .font(.system(size: 12))
                ScrollView {
                    LazyVStack(spacing: 3) {
                        if visible.isEmpty {
                            Text(search.isEmpty ? "No sessions in this view. Connect an agent or browse saved chats." : "No matching tasks or projects.")
                                .font(.system(size: 14)).foregroundStyle(Palette.muted).padding(.vertical, 30)
                        }
                        ForEach(visible) { session in
                            Button { store.select(session.id) } label: { WorkRow(store: store, session: session) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                Text("\(store.sessions.filter { $0.connected && !$0.isSaved && !$0.needsSetup }.count) sessions connected")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }.padding(18).frame(minWidth: 260, idealWidth: 280, maxWidth: 300)
                .background(Palette.sidebar)
            Divider()
            if let selected = store.selected {
                WorkDetail(store: store, session: selected).id(selected.id)
            } else {
                VStack(alignment: .leading, spacing: 15) {
                    Text("Stay with your work.").font(.system(size: 21, weight: .semibold))
                    Text("Select an agent to review its activity, answer a question, or open its terminal.")
                        .font(.system(size: 14)).foregroundStyle(Palette.muted)
                    Text("New decisions appear here and in the floating panel. Running tools do not need your attention unless the agent asks.")
                        .font(.system(size: 14)).foregroundStyle(Palette.muted)
                }.padding(42).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .onAppear { updateOrder() }
        .onChange(of: store.sessions.map(\.id).sorted()) { updateOrder() }
        .onChange(of: filter) { if filter == "Saved" { store.waitingOnly = false } }
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
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 9) {
                Circle().fill(store.sessionColor(session)).frame(width: 6, height: 6).padding(.top, 5)
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text("\(session.projectLabel) · \(stateName(session.state))")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                    Text(session.workHeadline).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                if !session.requests.isEmpty {
                    Circle().fill(Palette.accent).frame(width: 4, height: 4).padding(.top, 5)
                        .accessibilityLabel("\(session.requests.count) waiting decisions")
                }
            }
        }.padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Palette.ink)
            .background(store.selectedID == session.id ? Color.white.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .help("\(session.name)\n\(agentName(session.agent)) · \(session.cwd)\n\(session.workHeadline)")
    }
}

private struct WorkDetail: View {
    @ObservedObject var store: Store
    let session: SessionRecord
    @State private var tab = "Decision"
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Circle().fill(store.sessionColor(session)).frame(width: 7, height: 7).padding(.top, 8)
                VStack(alignment: .leading, spacing: 7) {
                    Text(session.name).font(.system(size: 19, weight: .semibold)).textSelection(.enabled)
                    Text("\(session.projectLabel) · \(agentName(session.agent)) · \(stateName(session.state))")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
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
            Divider()
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
                RequestEditor(store: store, session: session, request: request).id(request.id)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(session.workHeadline).font(.system(size: 19, weight: .medium)).textSelection(.enabled)
                    Text(session.baseState == "ready" ? "The agent is idle. This does not confirm that its task or tests succeeded." :
                            "No decision is waiting on you. Activity below is what the agent has actually reported.")
                        .font(.system(size: 14)).foregroundStyle(Palette.muted)
                    SessionTimeline(store: store, showsHeader: false)
                }
            }
        }.padding(26).frame(minWidth: 410, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.surface)
    }
}
