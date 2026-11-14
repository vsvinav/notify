import SwiftUI
import AppKit
import NotifyCore

enum Palette {
    static let background = Color(red: 0.065, green: 0.071, blue: 0.085)
    static let sidebar = Color(red: 0.085, green: 0.092, blue: 0.108)
    static let surface = background
    static let raised = Color.white.opacity(0.07)
    static let ink = Color(red: 0.91, green: 0.93, blue: 0.95)
    static let line = Color.white.opacity(0.09)
    static let muted = Color(red: 0.65, green: 0.70, blue: 0.74)
    static let accent = Color(red: 0.57, green: 0.84, blue: 0.73)
    static let amber = Color(red: 0.94, green: 0.73, blue: 0.43)
    static func state(_ state: String) -> Color {
        switch state {
        case "waiting": return amber
        case "working", "starting": return muted
        case "ready": return accent
        case "error": return .red
        default: return muted
        }
    }
}

func agentName(_ value: String) -> String {
    switch value { case "claude": return "Claude Code"; case "copilot": return "Copilot"; default: return "Demo" }
}
func stateName(_ value: String) -> String {
    switch value {
    case "waiting": return "Needs you"
    case "working": return "Working"
    case "starting": return "Connecting"
    case "ready": return "Idle"
    case "error": return "Error"
    case "setup": return "Connect extension"
    case "saved": return "Saved"
    default: return "Disconnected"
    }
}

struct AgentIcon: View {
    let agent: String
    var body: some View {
        Image(systemName: agent == "claude" ? "sparkle" : "terminal")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(agent == "claude" ? Palette.amber : Color(red: 0.68, green: 0.77, blue: 0.93))
            .frame(width: 32, height: 32)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(agentName(agent))
    }
}

struct SmallLabel: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted) }
}

struct DashboardView: View {
    @ObservedObject var store: Store
    var body: some View {
        WorkOverview(store: store)
        .background(Palette.background)
        .foregroundStyle(Palette.ink)
        .preferredColorScheme(.dark)
        .tint(Palette.accent)
        .sheet(isPresented: $store.settingsVisible) { SettingsView(store: store) }
        .safeAreaInset(edge: .bottom) {
            if let error = store.error {
                HStack {
                    Text(error).font(.system(size: 12)).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { store.error = nil }
                }.padding(12).foregroundStyle(Palette.amber).background(Palette.surface)
            }
        }
    }
}

struct SessionCard: View {
    let session: SessionRecord
    let synopsis: String
    let autoYes: Bool
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top, spacing: 10) {
                    AgentIcon(agent: session.agent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.name).font(.system(size: 13, weight: .semibold)).lineLimit(2).help(session.name)
                        Text("\(agentName(session.agent)) / \(session.cwd.isEmpty ? String(session.id.prefix(8)) : URL(fileURLWithPath: session.cwd).lastPathComponent)").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Circle().fill(Palette.state(session.state)).frame(width: 6, height: 6)
                }
                Text(session.requests.first?.title ?? (synopsis.isEmpty ? "No description yet" : synopsis))
                    .font(.system(size: 12)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Text(stateName(session.state)).foregroundStyle(Palette.state(session.state))
                    Spacer()
                    if autoYes { Text("AUTO-YES ON").foregroundStyle(Palette.amber) }
                    if session.requests.count > 1 { Text("\(session.requests.count) requests") }
                    Image(systemName: "arrow.right")
                }.font(.system(size: 10)).foregroundStyle(Palette.muted)
            }.padding(15).background(selected ? Palette.raised : Palette.surface, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Palette.accent.opacity(0.75) : Palette.line, lineWidth: 1))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct SessionDescriptionView: View {
    @ObservedObject var store: Store
    let session: SessionRecord
    @State private var target: SessionRecord?
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            let description = store.description(for: session)
            Text(description?.text ?? (session.synopsis.isEmpty ? "No description yet." : session.synopsis))
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let description {
                Text("AI / \(description.model) / \(description.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 9)).foregroundStyle(Palette.muted)
            }
            if session.agent == "copilot" {
                HStack {
                    if store.summarizingID == session.id { ProgressView().controlSize(.mini) }
                    Button(store.summarizingID == session.id ? "Summarizing..." : (description == nil ? "Summarize" : "Refresh description")) { target = session }
                        .disabled(store.summarizingID != nil).buttonStyle(.plain).foregroundStyle(Palette.accent)
                        .help("Uses Haiku through your Copilot account only when requested.")
                }.font(.system(size: 11))
            }
        }
        .alert("Generate an AI description?", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }), presenting: target) { selected in
            Button("Cancel", role: .cancel) { target = nil }
            Button("Summarize") { store.summarize(selected); target = nil }
        } message: { selected in
            Text("Send up to 12,000 characters of conversation text from “\(selected.name)” to Haiku through your Copilot account. This uses your account allowance. Tool results are excluded. The original chat stays untouched; nothing runs automatically.")
        }
    }
}

struct ReadableContext: View {
    let fields: [ContextField]
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: 5) {
                    if !field.label.isEmpty {
                        Text(field.displayLabel).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
                    }
                    if field.presentation == .diff {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(field.value.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                                let added = line.hasPrefix("+") && !line.hasPrefix("+++")
                                let removed = line.hasPrefix("-") && !line.hasPrefix("---")
                                Text(line.isEmpty ? " " : line).font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(added ? Palette.accent : (removed ? Color(red: 1, green: 0.62, blue: 0.65) : Palette.ink))
                                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.textSelection(.enabled)
                    } else {
                        Text(field.value.isEmpty ? "(empty content)" : field.value)
                            .font(.system(size: 12, design: field.presentation == .code ? .monospaced : .default))
                            .foregroundStyle(field.presentation == .warning ? Palette.amber : Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                }.padding(field.presentation == .text ? 0 : 12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(field.presentation == .text ? Color.clear : Palette.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

struct RequestEditor: View {
    @ObservedObject var store: Store
    @FocusState private var feedbackFocused: Bool
    @FocusState private var answerFocused: String?
    let session: SessionRecord
    let request: AgentRequest
    var floating = false
    private var feedback: String {
        get { store.replyWorkspace.drafts[request.id]?.feedback ?? "" }
        nonmutating set {
            var draft = store.replyWorkspace.drafts[request.id] ?? ReplyDraft()
            draft.feedback = newValue
            store.replyWorkspace.drafts[request.id] = draft
        }
    }
    private var denialFeedback: String? {
        let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
    private var selections: [String: [String]] {
        get { store.replyWorkspace.drafts[request.id]?.selections ?? [:] }
        nonmutating set {
            var draft = store.replyWorkspace.drafts[request.id] ?? ReplyDraft()
            draft.selections = newValue
            store.replyWorkspace.drafts[request.id] = draft
        }
    }
    private var freeText: [String: String] {
        get { store.replyWorkspace.drafts[request.id]?.freeText ?? [:] }
        nonmutating set {
            var draft = store.replyWorkspace.drafts[request.id] ?? ReplyDraft()
            draft.freeText = newValue
            store.replyWorkspace.drafts[request.id] = draft
        }
    }
    private var answers: [String: [String]] {
        (store.replyWorkspace.drafts[request.id] ?? ReplyDraft()).answers(for: request)
    }
    private var keyboardChoice: ReplyChoice { store.replyWorkspace.choice(for: request) }
    private func shortcut(for choice: ReplyChoice) -> KeyboardShortcut? {
        !feedbackFocused && !store.editingReplyText && keyboardChoice == choice ? .defaultAction : nil
    }
    var body: some View {
        ScrollViewReader { proxy in
        VStack(alignment: .leading, spacing: 11) {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    Text(.init(request.title)).font(.system(size: 17, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if request.kind == "question" {
                        ForEach(request.questions) { question in questionField(question) }
                    }
                    let fields = RequestContext.fields(from: request.detail, isQuestion: request.kind == "question")
                    if !fields.isEmpty {
                        if request.kind == "permission" {
                            let decisionFields = fields.filter(\.isDecisionDetail)
                            if !decisionFields.isEmpty {
                                ReadableContext(fields: decisionFields)
                                let otherFields = fields.filter { !$0.isDecisionDetail }
                                DisclosureGroup("Request details") {
                                    VStack(alignment: .leading, spacing: 9) {
                                        if !session.cwd.isEmpty {
                                            Text("Project: \(session.cwd)").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                        }
                                        ReadableContext(fields: otherFields)
                                    }.padding(.top, 7)
                                }.font(.system(size: 11)).foregroundStyle(Palette.muted)
                            } else {
                                ReadableContext(fields: fields)
                            }
                        } else {
                            DisclosureGroup("Full context") {
                                ReadableContext(fields: fields).padding(.top, 7)
                            }.font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                    }
                    if !session.output.isEmpty {
                        DisclosureGroup("Recent conversation") {
                            Text(session.output).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled).padding(.top, 7)
                        }.font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 95, maxHeight: .infinity).scrollIndicators(.visible)
            if let error = store.requestErrors[request.id] ?? store.sessionErrors[session.id] ?? store.error {
                Text(error).font(.system(size: 12)).foregroundStyle(Palette.amber)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            ViewThatFits(in: .vertical) {
                approvalActions.fixedSize(horizontal: false, vertical: true)
                ScrollView { approvalActions }.frame(maxHeight: 280).scrollIndicators(.visible)
            }.layoutPriority(1)
            if request.kind == "permission" && request.supportsFeedback == true {
                TextField("Denial instructions", text: Binding(get: { feedback }, set: { feedback = $0 }),
                          prompt: Text("Tell Copilot what to do differently (optional)").foregroundColor(Palette.muted), axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...3).font(.system(size: 12))
                    .padding(9).background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(feedbackFocused ? Palette.accent : Palette.line, lineWidth: feedbackFocused ? 2 : 1))
                    .focused($feedbackFocused)
                    .disabled(store.sending.contains(request.id))
                if feedback.utf16.count > 4000 {
                    Text("Keep instructions within 4,000 characters.").font(.system(size: 12)).foregroundStyle(Palette.amber)
                }
            }
            Button(request.kind == "question" ? "Decline" : (denialFeedback == nil ? "Deny" : "Deny with instructions")) {
                store.reply(session: session.id, request: request, decision: "deny", feedback: denialFeedback)
            }.buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                .foregroundStyle(keyboardChoice == .deny ? Palette.accent : Palette.ink)
                .keyboardShortcut(shortcut(for: .deny)).id(ReplyChoice.deny)
                .disabled(store.sending.contains(request.id) || !session.connected ||
                          !request.accepts(decision: "deny", answers: [:], feedback: denialFeedback))
            if store.sending.contains(request.id) {
                HStack { ProgressView().controlSize(.mini); Text("Waiting for launcher confirmation").font(.system(size: 10)) }.foregroundStyle(Palette.muted)
            } else {
                Button("Snooze for 5 minutes") { store.snooze(request.id) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
        }.frame(maxHeight: .infinity, alignment: .top)
            .onChange(of: keyboardChoice) { _, value in proxy.scrollTo(value, anchor: .center) }
            .onChange(of: store.answerFocus) { _, value in
                guard floating, let value, value.requestID == request.id else { return }
                answerFocused = value.questionID
            }
        }
    }
    private var approvalActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            if request.kind == "permission" {
                Button { store.reply(session: session.id, request: request, decision: "allow") } label: {
                    HStack(spacing: 7) {
                        Text("Allow once")
                        Spacer()
                        Image(systemName: "return").font(.system(size: 11)).accessibilityHidden(true)
                    }
                }.buttonStyle(ReplyButtonStyle(primary: true, highlighted: keyboardChoice == .allowOnce))
                    .keyboardShortcut(shortcut(for: .allowOnce)).id(ReplyChoice.allowOnce)
                    .help("Up and Down choose an option. Return activates the highlighted option, including remembered scopes. Text editing keeps normal keys.")
                ForEach(request.permissionOptions ?? []) { option in
                    Button {
                        store.reply(session: session.id, request: request, decision: "allow", permissionOptionID: option.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.label).fontWeight(.medium)
                            Text(option.detail).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(ReplyButtonStyle(primary: false, highlighted: keyboardChoice == .scope(option.id)))
                        .keyboardShortcut(shortcut(for: .scope(option.id))).id(ReplyChoice.scope(option.id))
                }
                if !(request.permissionOptions ?? []).isEmpty {
                    Text("Remembered approvals skip future prompts within their scope.")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Button("Send answer") { store.reply(session: session.id, request: request, decision: "answer", answers: answers) }
                    .buttonStyle(ReplyButtonStyle(primary: true, highlighted: keyboardChoice == .send))
                    .keyboardShortcut(shortcut(for: .send)).id(ReplyChoice.send)
                    .disabled(!request.accepts(decision: "answer", answers: answers))
            }
        }.disabled(store.sending.contains(request.id) || !session.connected)
    }
    private func questionField(_ question: AgentQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.text + (question.required == false ? " (optional)" : "")).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            if question.multiple { Text("Choose any that apply").font(.system(size: 10)).foregroundStyle(Palette.muted) }
            ForEach(question.options, id: \.self) { option in
                let selected = selections[question.id]?.contains(option.label) == true
                Button {
                    store.replyWorkspace.toggleOption(option.label, question: question, request: request)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: selected ? (question.multiple ? "checkmark.square.fill" : "largecircle.fill.circle") : (question.multiple ? "square" : "circle"))
                            .foregroundStyle(selected ? Palette.accent : Palette.muted)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.label).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                            if !option.description.isEmpty { Text(option.description).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true) }
                        }
                        Spacer(minLength: 0)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(selected ? Color.white.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(
                            keyboardChoice == .option(question: question.id, label: option.label) ? Palette.accent : .clear, lineWidth: 2))
                }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                    .keyboardShortcut(shortcut(for: .option(question: question.id, label: option.label)))
                    .id(ReplyChoice.option(question: question.id, label: option.label))
            }
            if question.allowFreeform {
                if !question.options.isEmpty {
                    Label("Other", systemImage: (freeText[question.id] ?? "").isEmpty ? "circle" : "largecircle.fill.circle")
                        .font(.system(size: 13, weight: .medium)).padding(.top, 4)
                }
                TextField(question.options.isEmpty ? "Your answer" : "Type your own answer", text: Binding(
                    get: { freeText[question.id] ?? "" },
                    set: { freeText[question.id] = $0; if !question.multiple && !$0.isEmpty { selections[question.id] = [] } }
                ), axis: .vertical).textFieldStyle(.plain).font(.system(size: 13)).lineLimit(2...5)
                    .padding(11).background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line))
                    .accessibilityLabel(question.text)
                    .focused($answerFocused, equals: question.id)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(keyboardChoice == .input(question.id) ? Palette.accent : .clear, lineWidth: 2))
                    .id(ReplyChoice.input(question.id))
            }
        }
    }
}

struct ReplyButtonStyle: ButtonStyle {
    let primary: Bool
    var highlighted = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: primary ? .semibold : .regular))
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 9)
            .foregroundStyle(Palette.ink)
            .background(Color.white.opacity(primary ? 0.12 : 0.035), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(highlighted ? Palette.accent : (primary ? Color.white.opacity(0.13) : Palette.line),
                                                           lineWidth: highlighted ? 2 : 1))
            .opacity(!enabled ? 0.4 : (configuration.isPressed ? 0.7 : 1))
    }
}

struct FloatingView: View {
    @ObservedObject var store: Store
    let openCenter: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let id = store.steeringSessionID {
                FloatingSteeringView(store: store, sessionID: id, openCenter: openCenter)
            } else if let item = store.activeFloatingRequest {
                let index = store.floatingRequests.firstIndex { $0.request.id == store.replyWorkspace.floatingID } ?? 0
                HStack(spacing: 9) {
                    Circle().fill(floatingColor).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.session.name).font(.system(size: 13, weight: .semibold)).lineLimit(2).help(item.session.name)
                        Text("\(item.session.projectLabel) · \(agentName(item.session.agent))").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Text("\(min(index + 1, store.floatingRequests.count))/\(store.floatingRequests.count)").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Divider()
                if store.automation.enabled.contains(item.session.id) { AutoYesWarning() }
                RequestEditor(store: store, session: item.session, request: item.request, floating: true).id(item.request.id)
                Divider()
                Text("↑ ↓ choose · Return selects").font(.system(size: 10)).foregroundStyle(Palette.muted)
                HStack {
                    Button(store.floatingExpanded ? "Compact" : "Expand") { store.floatingExpanded.toggle() }
                    Menu("Session") {
                        Button("Open session") { store.select(item.session.id, request: item.request.id); openCenter() }
                        Button("Open in iTerm2") { store.openTerminal(item.session) }.disabled(item.session.ownerPID == nil)
                        Button("Steer") { store.showSteering(item.session.id) }.disabled(!item.session.canSteer)
                    }
                    Spacer()
                    if store.floatingRequests.count > 1 {
                        Button("Next request") { store.replyWorkspace.next(requestIDs: store.floatingRequests.map { $0.request.id }) }
                    }
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }.padding(19).background(floatingSurface).clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.white.opacity(0.14), lineWidth: 1))
            .foregroundStyle(Palette.ink).preferredColorScheme(.dark).tint(Palette.accent)
    }
    private var floatingSurface: Color {
        let id = store.steeringSessionID ?? store.floatingRequests.first(where: { $0.request.id == store.replyWorkspace.floatingID })?.session.id ?? store.floatingRequests.first?.session.id
        return id.flatMap { store.registry.sessions[$0] }.map { store.sessionSurface($0) } ?? Palette.background
    }
    private var floatingColor: Color {
        let id = store.steeringSessionID ?? store.floatingRequests.first(where: { $0.request.id == store.replyWorkspace.floatingID })?.session.id ?? store.floatingRequests.first?.session.id
        return id.flatMap { store.registry.sessions[$0] }.map { store.sessionColor($0) } ?? Palette.accent
    }
}

struct SettingsView: View {
    @ObservedObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("Settings").font(.system(size: 23, weight: .semibold)); Spacer(); Button("Done") { store.settingsVisible = false } }
            Toggle("Safe auto-yes", isOn: $store.autoYes)
            Text("Only explicitly identified reads of source or documentation files inside the current project qualify. Hidden paths, sensitive names, symlink escapes, commands, writes, and questions stay manual. Existing agent permission rules still apply.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
            Toggle("Show floating requests", isOn: $store.floatingEnabled)
            Toggle("Play a quiet sound for new requests", isOn: $store.playSound)
            Divider()
            HStack { Text("Approval history").font(.system(size: 14, weight: .medium)); Spacer(); Text("Last 200 decisions").font(.system(size: 10)).foregroundStyle(Palette.muted) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if store.audit.isEmpty { Text("No decisions recorded yet.").foregroundStyle(Palette.muted) }
                    ForEach(store.audit) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.action).font(.system(size: 11, weight: .medium))
                            Text("\(entry.session) / \(entry.automatic ? "Automatic" : "You") / \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 10)).foregroundStyle(Palette.muted)
                        }
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 180)
            Text("History contains session labels and decisions, not answers. Conversation previews stay on this Mac unless you explicitly request an AI description; that sends a limited excerpt through your Copilot account.")
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
            Button("Remove disconnected sessions") { store.clearDisconnected() }
        }.padding(28).frame(width: 550).background(Palette.background).foregroundStyle(Palette.ink).preferredColorScheme(.dark).tint(Palette.accent)
    }
}
