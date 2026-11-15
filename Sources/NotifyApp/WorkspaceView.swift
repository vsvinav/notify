import SwiftUI
import AppKit
import NotifyCore

extension Store {
    func sessionSurface(_ session: SessionRecord) -> Color {
        Palette.notificationSurface(for: appearance.color(for: session))
    }
    func sessionColor(_ session: SessionRecord) -> Color {
        let rgb = appearance.color(for: session)
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}

struct SessionColorPicker: View {
    @ObservedObject var store: Store
    let session: SessionRecord
    var body: some View {
        HStack {
            ColorPicker("Session color", selection: Binding(get: { store.sessionColor(session) }, set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { store.error = "This color cannot be converted to RGB."; return }
                let r = UInt32((min(1, max(0, rgb.redComponent)) * 255).rounded())
                let g = UInt32((min(1, max(0, rgb.greenComponent)) * 255).rounded())
                let b = UInt32((min(1, max(0, rgb.blueComponent)) * 255).rounded())
                store.setColor(r << 16 | g << 8 | b, for: session)
            }), supportsOpacity: false)
            Button("Reset") { store.setColor(nil, for: session) }
                .help("Reset to automatic session color")
        }.font(.system(size: 11))
    }
}

struct SessionColorChoices: View {
    @ObservedObject var store: Store
    let sessionID: String
    @State private var colors: [UInt32]
    @State private var hoveredColor: UInt32?
    private static let names: [UInt32: String] = [
        0xA6C8FF: "Sky", 0xD8AFF5: "Lilac", 0x70D6C4: "Mint", 0xEAAFBC: "Rose",
        0xC1D58D: "Sage", 0xE5BF8C: "Sand", 0xA9B6EF: "Periwinkle", 0x8ACBDF: "Aqua",
        0xF29A78: "Terracotta", 0xB9B0A3: "Stone",
        0x4772C4: "Cobalt", 0x338D91: "Teal", 0x4D7E64: "Pine", 0x898642: "Olive",
        0xC59639: "Ochre", 0xD17C41: "Tangerine", 0xB65D50: "Brick", 0xAC5278: "Berry",
        0x805D9B: "Plum", 0x647485: "Slate"
    ]
    init(store: Store, sessionID: String) {
        self.store = store
        self.sessionID = sessionID
        _colors = State(initialValue: store.registry.sessions[sessionID].map {
            store.appearance.suggestedColors(for: $0, among: store.sessions)
        } ?? [])
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Session color").font(WorkspaceType.text(19, strong: true))
                Spacer()
                Button("Done") { store.floatingColorPickerSessionID = nil }
                    .keyboardShortcut(.cancelAction).buttonStyle(.plain)
                    .font(WorkspaceType.text(12)).foregroundStyle(Palette.accent)
            }
            if let session = store.registry.sessions[sessionID] {
                let current = store.appearance.color(for: session)
                Text(session.name).font(WorkspaceType.text(12)).foregroundStyle(Palette.muted).lineLimit(2)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 10), count: 5), spacing: 10) {
                    ForEach(colors, id: \.self) { color in
                        Button { store.setColor(color, for: session) } label: {
                            Circle()
                                .fill(Color(red: Double((color >> 16) & 255) / 255,
                                            green: Double((color >> 8) & 255) / 255,
                                            blue: Double(color & 255) / 255))
                                .overlay(Circle().strokeBorder(Palette.line, lineWidth: 1))
                                .frame(width: 30, height: 30).padding(5)
                                .overlay(Circle().strokeBorder(current == color ? Palette.accent :
                                                                hoveredColor == color ? Palette.line : .clear,
                                                              lineWidth: current == color ? 2 : 1))
                                .contentShape(Circle())
                        }.buttonStyle(.plain)
                            .onHover { hoveredColor = $0 ? color : nil }
                            .accessibilityLabel(Self.names[color] ?? String(format: "#%06X", color))
                            .accessibilityAddTraits(current == color ? .isSelected : [])
                            .help(Self.names[color] ?? String(format: "#%06X", color))
                    }
                }
                HStack {
                    Text(Self.names[current] ?? String(format: "#%06X", current))
                        .font(WorkspaceType.text(13, strong: true))
                    Spacer()
                    Button {
                        guard let next = store.appearance.suggestedColors(for: session, among: store.sessions).first(where: { $0 != current }) else {
                            store.error = "No alternative session color is available."
                            return
                        }
                        store.setColor(next, for: session)
                    } label: {
                        Label("Next color", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.plain).font(WorkspaceType.text(12)).foregroundStyle(Palette.accent)
                    .help("Choose the next least-used color across connected sessions")
                }
                if let error = store.error {
                    Text(error).font(.system(size: 11)).foregroundStyle(Palette.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                HStack {
                    Button("Reset automatic") { store.setColor(nil, for: session) }
                        .buttonStyle(.plain).font(WorkspaceType.text(12)).foregroundStyle(Palette.accent)
                    Spacer()
                    Text("Least-used first").font(WorkspaceType.text(11)).foregroundStyle(Palette.muted)
                }
            } else {
                Text("This session is no longer available.").foregroundStyle(Palette.muted)
            }
        }.padding(20).frame(width: 280).background(Palette.surface)
            .foregroundStyle(Palette.ink).tint(Palette.accent)
            .onAppear {
                if let session = store.registry.sessions[sessionID] {
                    colors = store.appearance.suggestedColors(for: session, among: store.sessions)
                }
            }
    }
}

struct SessionBrowser: View {
    @ObservedObject var store: Store
    @State private var search = ""
    private var matches: [SessionRecord] {
        store.sessions.filter { search.isEmpty || "\($0.name) \($0.cwd) \($0.id)".localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "bolt.fill").foregroundStyle(Palette.accent)
                Text("notify").font(.system(size: 24, weight: .semibold))
                Spacer()
                Button { store.settingsVisible = true } label: { Image(systemName: "slider.horizontal.3") }.help("Settings")
            }
            TextField("Search chats or projects", text: $search).textFieldStyle(.roundedBorder)
            Toggle(isOn: $store.waitingOnly) {
                Label("Needs you (\(store.pending.count))", systemImage: "tray")
                    .foregroundStyle(Palette.amber)
            }.toggleStyle(.button).font(.system(size: 12))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if matches.isEmpty {
                        Text("No matching sessions.\nStart an agent in iTerm2 to connect.").foregroundStyle(Palette.muted).font(.system(size: 12))
                    }
                    if !matches.filter({ !$0.requests.isEmpty }).isEmpty { SmallLabel(text: "Needs you") }
                    ForEach(matches.filter { !$0.requests.isEmpty }) { row($0) }
                    if !store.waitingOnly {
                        SmallLabel(text: "Live & recent").padding(.top, 12)
                        ForEach(matches.filter { $0.requests.isEmpty && !$0.isSaved }) { row($0) }
                        SmallLabel(text: "Saved chats").padding(.top, 12)
                        ForEach(matches.filter(\.isSaved)) { row($0) }
                    }
                }
            }
            Text("Local to your Mac").font(.system(size: 10)).foregroundStyle(Palette.muted)
        }.padding(16).background(Palette.sidebar)
    }
    private func row(_ session: SessionRecord) -> some View {
        Button { store.select(session.id) } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 3).fill(store.sessionColor(session)).frame(width: 4)
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                    Text("\(session.projectLabel) / \(agentName(session.agent))").font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
                    Text(session.requests.isEmpty ? stateName(session.state) : "\(session.requests.count) decision\(session.requests.count == 1 ? "" : "s")")
                        .font(.system(size: 10)).foregroundStyle(Palette.state(session.state))
                    if session.isSaved && session.updated != .distantPast {
                        Text(session.updated.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 9)).foregroundStyle(Palette.muted)
                    }
                }
                Spacer(minLength: 0)
            }.padding(10).background(store.selectedID == session.id ? Palette.raised : Palette.surface, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).help("\(session.name)\n\(session.cwd)\n\(session.id)")
    }
}

private struct ActivityBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct SessionTimeline: View {
    @ObservedObject var store: Store
    var showsHeader = true
    var body: some View {
        if let session = store.selected {
            ActivityTimeline(store: store, session: session, showsHeader: showsHeader).id(session.id)
        } else {
            VStack(spacing: 15) {
                Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 34, weight: .light))
                Text("Your agents, without the tab hunting.").font(.headline)
                Text("Select a chat to see activity and decisions.\nExisting terminals stay in control.")
                    .font(.system(size: 12)).multilineTextAlignment(.center)
            }.foregroundStyle(Palette.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct TerminalSessionButton: View {
    @ObservedObject var store: Store
    let session: SessionRecord
    @State private var confirmResume = false
    var body: some View {
        Button(store.terminalBusy.contains(session.id) || store.launching.contains(session.id) ? "Opening..." :
                (session.isSaved ? "Resume in iTerm2" : "Open in iTerm2")) {
            if session.isSaved { confirmResume = true }
            else { store.openTerminal(session) }
        }.disabled(session.agent != "copilot" || store.terminalBusy.contains(session.id) || store.launching.contains(session.id) || session.cwd.isEmpty)
            .alert("Resume this saved chat in iTerm2?", isPresented: $confirmResume) {
                Button("Cancel", role: .cancel) {}
                Button("Resume") { store.openTerminal(session, resume: true) }
            } message: {
                Text("Open “\(session.name)” in its project folder using the original Copilot CLI. Saved model, mode and permission settings (including allow-all, if previously enabled) carry over. Notify's session Auto-yes stays off.\n\nNo prompt or extension consent is sent automatically. A running owner will be opened instead of creating a duplicate.")
            }
    }
}

private struct ActivityTimeline: View {
    @ObservedObject var store: Store
    let session: SessionRecord
    var showsHeader = true
    @State private var follow = true
    @State private var nearBottom = true
    private var responses: [ActivityEntry] {
        session.activity.entries.filter { ResponseFeed.includes(kind: $0.kind, agentID: $0.agentID) }
    }
    private var emptyMessage: String {
        if !session.hasActivityFeed {
            return "Responses appear here when the Notify extension is connected. Earlier conversation stays in iTerm2."
        }
        if session.state == "working" {
            return "The agent is working. Its next response will appear here."
        }
        return "No responses yet. The agent’s next reply will appear here."
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsHeader {
            HStack(alignment: .top) {
                Circle().fill(store.sessionColor(session)).frame(width: 12, height: 12).padding(.top, 7)
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.name).font(.system(size: 23, weight: .semibold)).textSelection(.enabled)
                    Text("\(session.projectLabel) / \(agentName(session.agent)) / \(session.id.prefix(8))")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }
            HStack {
                Label(stateName(session.state), systemImage: session.requests.isEmpty ? "circle.dotted" : "questionmark.circle")
                    .foregroundStyle(Palette.state(session.state))
                Spacer()
                TerminalSessionButton(store: store, session: session)
                Button("Steer") { store.showSteering(session.id) }.disabled(!session.connected)
            }.font(.system(size: 12))
            if let error = store.sessionErrors[session.id] {
                Text(error).font(.system(size: 12)).foregroundStyle(Palette.amber).textSelection(.enabled)
            }

            Divider()
            }
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            if session.activity.truncated {
                                Text("Earlier responses remain in iTerm2.")
                                    .font(WorkspaceType.text(11)).foregroundStyle(Palette.muted)
                            }
                            if responses.isEmpty {
                                Text(emptyMessage)
                                    .font(WorkspaceType.text(13)).foregroundStyle(Palette.muted)
                                    .fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
                            }
                            ForEach(responses) { entry in
                                ActivityRow(entry: entry)
                                if entry.id != responses.last?.id {
                                    Divider()
                                }
                            }
                            Color.clear.frame(height: 1).id("bottom")
                                .background(GeometryReader { marker in
                                    Color.clear.preference(key: ActivityBottomKey.self, value: marker.frame(in: .named("activity")).maxY)
                                })
                        }.padding(.vertical, 10)
                    }.coordinateSpace(name: "activity")
                        .background(ActivityScrollIntent { follow = false })
                        .onAppear {
                            DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                        .onChange(of: follow) { _, enabled in
                            if enabled { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                        .onPreferenceChange(ActivityBottomKey.self) { y in nearBottom = y < geometry.size.height + 80 }
                        .onChange(of: responses) { _, _ in
                            if follow && nearBottom { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                        .safeAreaInset(edge: .bottom) {
                            HStack {
                                Toggle("Follow live", isOn: $follow).toggleStyle(.checkbox)
                                Spacer()
                                Button("Latest response") { follow = true; proxy.scrollTo("bottom", anchor: .bottom) }
                            }.font(WorkspaceType.text(11)).padding(9).background(Palette.background)
                        }
                }
            }
        }.padding(showsHeader ? 22 : 0)
    }
}

private struct ActivityScrollIntent: NSViewRepresentable {
    let pause: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak view, weak coordinator = context.coordinator] event in
            if let view, let window = view.window, event.window === window,
               event.scrollingDeltaY > 0, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
               view.bounds.contains(view.convert(event.locationInWindow, from: nil)) {
                coordinator?.pause()
            }
            return event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.pause = pause }
    func makeCoordinator() -> Coordinator { Coordinator(pause: pause) }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    final class Coordinator {
        var pause: () -> Void
        var monitor: Any?
        init(pause: @escaping () -> Void) { self.pause = pause }
    }
}

private struct ActivityRow: View {
    let entry: ActivityEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let blocks = ResponseMarkdown.blocks(entry.detail)
            if blocks.isEmpty {
                Text(entry.status == "running" ? "Writing a response…" : "No response text was shared.")
                    .font(WorkspaceType.text(13)).foregroundStyle(Palette.muted)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                        ResponseBlockView(block: block, isFirst: index == 0)
                            .padding(.top, blockSpacing(blocks, at: index))
                    }
                }
            }
            if entry.status == "running" && !blocks.isEmpty {
                Text("Writing…").font(WorkspaceType.text(11)).foregroundStyle(Palette.muted)
            } else if entry.status == "failed" {
                Text("Response interrupted. Any text received is shown above.")
                    .font(WorkspaceType.text(11)).foregroundStyle(Palette.error)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func blockSpacing(_ blocks: [ResponseBlock], at index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        if case .listItem = blocks[index], case .listItem = blocks[index - 1] { return 4 }
        return 12
    }
}

private struct ResponseBlockView: View {
    let block: ResponseBlock
    let isFirst: Bool

    var body: some View {
        Group {
            switch block {
            case .paragraph(let text):
                prose(text).font(WorkspaceType.text(13))
            case .heading(let level, let text):
                prose(text).font(WorkspaceType.text(level == 1 ? 21 : level == 2 ? 18 : 15, strong: true))
                    .padding(.top, isFirst ? 0 : 8)
                    .accessibilityAddTraits(.isHeader)
            case .listItem(let marker, let depth, let text):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(marker).foregroundStyle(Palette.muted)
                    prose(text).frame(maxWidth: .infinity, alignment: .leading)
                }.font(WorkspaceType.text(13)).padding(.leading, CGFloat(depth) * 12)
            case .code(let language, let text, let closed):
                ResponseCodeBlock(language: language, code: text, closed: closed)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func prose(_ source: String) -> some View {
        var text = ResponseMarkdown.inline(source)
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
            text[run.range].font = .system(size: 12, design: .monospaced)
        }
        return Text(text).foregroundStyle(Palette.ink).tint(Palette.accent)
            .lineSpacing(4).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ResponseCodeBlock: View {
    let language: String
    let code: String
    let closed: Bool
    @State private var copied = false
    @State private var copyFailed = false
    @State private var copyReset: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language.isEmpty ? "Code" : language)
                    .lineLimit(1).truncationMode(.tail).help(language.isEmpty ? "Code" : language)
                Spacer(minLength: 0)
                Button {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(code, forType: .string)
                    copyFailed = !copied
                    copyReset?.cancel()
                    copyReset = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        if !Task.isCancelled { copied = false }
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                    .disabled(code.isEmpty).help("Copy code exactly as received")
                    .accessibilityLabel("Copy \(language.isEmpty ? "" : language + " ")code")
            }.font(WorkspaceType.text(11, strong: true)).foregroundStyle(Palette.muted).padding(10)
            Divider()
            ScrollView(.horizontal) {
                Text(verbatim: code.isEmpty && !closed ? "Waiting for code…" : code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(code.isEmpty ? Palette.muted : Palette.ink)
                    .lineSpacing(3).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }.frame(minWidth: 0, maxWidth: .infinity)
            if copyFailed {
                Text("Couldn’t copy. Select the code and press ⌘C.")
                    .font(WorkspaceType.text(11)).foregroundStyle(Palette.error).padding(10)
            }
        }.background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line.opacity(0.35), lineWidth: 1))
            .onChange(of: code) { _, _ in copied = false; copyFailed = false }
            .onDisappear { copyReset?.cancel() }
    }
}
