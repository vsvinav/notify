import SwiftUI
import AppKit
import NotifyCore

enum Palette {
    static let background = adaptive(0xEAE3D8, 0x211F1C)
    static let surface = adaptive(0xF3EEE5, 0x292622)
    static let sidebar = adaptive(0xE7DFD2, 0x24211E)
    static let raised = adaptive(0xDCD0BE, 0x3C352C)
    static let ink = adaptive(0x34302A, 0xE9E0D2)
    static let line = adaptive(0x796B5A, 0xA18F78)
    static let muted = adaptive(0x60564B, 0xBFB2A0)
    static let accent = adaptive(0x765C3C, 0xCFAD7E)
    static let highlightInk = adaptive(0xFBF7F0, 0x27221C)
    static let noticeMuted = adaptive(0x594F44, 0xC4B7A5)
    static let amber = adaptive(0x754718, 0xE1BB82)
    static let error = adaptive(0x873B37, 0xE4A294)
    static let diffAdded = adaptive(0x335C3E, 0xA8C6A0)
    static let diffRemoved = adaptive(0x873B37, 0xDDA69E)

    static func notificationSurface(for color: UInt32) -> Color {
        adaptive(0xF0E8DC, 0x2C2823, tint: color)
    }

    private static func adaptive(_ light: UInt32, _ dark: UInt32, tint: UInt32? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb = isDark ? dark : light
            func channel(_ shift: UInt32) -> CGFloat {
                let base = CGFloat((rgb >> shift) & 255) / 255
                guard let tint else { return base }
                let amount: CGFloat = isDark ? 0.12 : 0.10
                return base * (1 - amount) + CGFloat((tint >> shift) & 255) / 255 * amount
            }
            return NSColor(srgbRed: channel(16), green: channel(8), blue: channel(0), alpha: 1)
        })
    }
    static func state(_ state: String) -> Color {
        switch state {
        case "waiting": return amber
        case "working", "starting": return muted
        case "ready": return accent
        case "error": return error
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
            .foregroundStyle(agent == "claude" ? Palette.amber : Palette.accent)
            .frame(width: 32, height: 32)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: 8))
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
        Group {
            if store.setupVisible { AgentSetupView(store: store) }
            else { WorkOverview(store: store) }
        }
        .background(Palette.background)
        .foregroundStyle(Palette.ink)
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
                .font(WorkspaceType.text(13)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let text = description?.text ?? (session.synopsis.isEmpty ? nil : session.synopsis) {
                CopyTextButton(text: text, label: "Copy summary")
            }
            if let description {
                Text("AI / \(description.model) / \(description.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 9)).foregroundStyle(Palette.muted)
            }
            if ["copilot", "claude"].contains(session.agent) {
                HStack {
                    if store.summarizingID == session.id { ProgressView().controlSize(.mini) }
                    Button(store.summarizingID == session.id ? "Summarizing..." : (description == nil ? "Summarize" : "Refresh description")) { target = session }
                        .disabled(store.summarizingID != nil).buttonStyle(.plain).foregroundStyle(Palette.accent)
                        .help("Uses Haiku through your \(agentName(session.agent)) account only when requested.")
                }.font(.system(size: 11))
            }
        }
        .alert("Generate an AI description?", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }), presenting: target) { selected in
            Button("Cancel", role: .cancel) { target = nil }
            Button("Summarize") { store.summarize(selected); target = nil }
        } message: { selected in
            Text("Send up to 12,000 characters of conversation text from “\(selected.name)” to Haiku for a summary of up to 250 words. This uses your account allowance. Tool results are excluded. The original chat stays untouched; nothing runs automatically.")
        }
    }
}

struct ReadableContext: View {
    let fields: [ContextField]
    var floating = false
    var prominentTargets = false
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: 5) {
                    if !field.label.isEmpty {
                        Text(prominentTargets ? field.displayLabel.replacingOccurrences(of: "^(Args|Arguments|Input) / ", with: "", options: .regularExpression) : field.displayLabel)
                            .font(.system(size: 10)).foregroundStyle(floating ? Palette.noticeMuted : Palette.muted)
                    }
                    if field.presentation == .diff {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(field.value.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                                let added = line.hasPrefix("+") && !line.hasPrefix("+++")
                                let removed = line.hasPrefix("-") && !line.hasPrefix("---")
                                Text(line.isEmpty ? " " : line).font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(added ? Palette.diffAdded : (removed ? Palette.diffRemoved : Palette.ink))
                                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.textSelection(.enabled)
                    } else {
                        Text(field.value.isEmpty ? "(empty content)" : field.value)
                            .font(.system(size: prominentTargets && field.targetLabel != nil ? 20 : 12,
                                          weight: prominentTargets && field.targetLabel != nil ? .medium : .regular,
                                          design: field.presentation == .code || prominentTargets && field.targetLabel != nil ? .monospaced : .default))
                            .foregroundStyle(field.presentation == .warning ? Palette.amber : Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
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
    var wide = false
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
    private var secondary: Color { floating ? Palette.noticeMuted : Palette.muted }
    private func shortcut(for choice: ReplyChoice) -> KeyboardShortcut? {
        !feedbackFocused && !store.editingReplyText && !store.setupVisible && store.floatingColorPickerSessionID == nil && keyboardChoice == choice ? .defaultAction : nil
    }
    var body: some View {
        let fields = RequestContext.fields(from: request.detail, isQuestion: request.kind == "question")
        let reasons = fields.filter { ["Intention", "Reason", "Decision Reason"].contains($0.label) }
        let targets = floating && request.kind == "permission" ? fields.filter { $0.targetLabel != nil } : []
        let highlights = targets.isEmpty ? [] : fields.filter { $0.targetLabel != nil || $0.presentation == .warning }
        let evidence = fields.filter { field in
            !reasons.contains { $0.id == field.id } && !highlights.contains { $0.id == field.id }
        }
        ScrollViewReader { proxy in
        VStack(alignment: .leading, spacing: 11) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if wide && request.kind == "permission" {
                        HStack(alignment: .top, spacing: 32) {
                            heading(reasons, highlights: highlights).frame(maxWidth: .infinity, alignment: .leading)
                            context(evidence, targets: targets).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        heading(reasons, highlights: highlights)
                        if request.kind == "question" {
                            ForEach(request.questions) { question in questionField(question) }
                        }
                        context(evidence, targets: targets).id(targets.isEmpty ? "request-evidence" : "secondary-evidence")
                    }
                    if !session.output.isEmpty {
                        DisclosureGroup("Recent conversation") {
                            Text(session.output).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled).padding(.top, 7)
                        }.font(.system(size: 11)).foregroundStyle(secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: wide ? 60 : 95, maxHeight: .infinity).scrollIndicators(.visible)
            if floating && (!evidence.isEmpty || !highlights.isEmpty) {
                Button {
                    proxy.scrollTo("request-evidence", anchor: .top)
                } label: {
                    Label("More request details", systemImage: "arrow.down.doc")
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.accent)
            }
            if let error = store.requestErrors[request.id] ?? store.sessionErrors[session.id] ?? store.error {
                Text(error).font(.system(size: 12)).foregroundStyle(Palette.amber)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            ViewThatFits(in: .vertical) {
                approvalActions(proxy).fixedSize(horizontal: false, vertical: true)
                ScrollView { approvalActions(proxy) }.frame(minHeight: 80, maxHeight: 280).scrollIndicators(.visible)
            }.layoutPriority(1)
            HStack {
                if request.kind == "question" { denialAction }
                Spacer()
                if store.sending.contains(request.id) {
                    HStack { ProgressView().controlSize(.mini); Text("Waiting for confirmation").font(.system(size: 10)) }.foregroundStyle(secondary)
                } else {
                    Button("Snooze 5 min") { store.snooze(request.id) }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(secondary)
                }
            }
        }.frame(maxHeight: .infinity, alignment: .top)
            .onChange(of: keyboardChoice) { _, value in proxy.scrollTo(value, anchor: .center) }
            .onChange(of: store.answerFocus) { _, value in
                guard floating, let value, value.requestID == request.id else { return }
                answerFocused = value.questionID
            }
        }
    }
    private func heading(_ reasons: [ContextField], highlights: [ContextField]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(.init(request.title)).font(WorkspaceType.text(floating ? 28 : 26))
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !highlights.isEmpty {
                ReadableContext(fields: highlights, floating: floating, prominentTargets: true).id("request-evidence")
            }
            ForEach(reasons) { reason in
                Text(reason.value).font(WorkspaceType.text(13)).foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }
    @ViewBuilder private func context(_ fields: [ContextField], targets: [ContextField]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if request.kind == "permission" {
                let resourceOnly = !targets.isEmpty && targets.allSatisfy {
                    ["URL", "URI"].contains($0.targetLabel ?? "") &&
                        ["http", "https"].contains(URLComponents(string: $0.value)?.scheme?.lowercased() ?? "")
                }
                if !session.cwd.isEmpty && !resourceOnly {
                    Text(session.cwd).font(.system(size: 11, design: .monospaced)).foregroundStyle(secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                let decisionFields = fields.filter {
                    targets.isEmpty ? $0.isDecisionDetail : !["Tool Name", "Server Name", "Request Id", "Session Id"].contains($0.label)
                }
                ReadableContext(fields: decisionFields.isEmpty && targets.isEmpty ? fields : decisionFields, floating: floating)
                let otherFields = fields.filter { field in !decisionFields.contains { $0.id == field.id } }
                if (!decisionFields.isEmpty || !targets.isEmpty) && (!otherFields.isEmpty || resourceOnly && !session.cwd.isEmpty) {
                    DisclosureGroup("Request details") {
                        if resourceOnly && !session.cwd.isEmpty {
                            Text("Working directory: \(session.cwd)").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        }
                        ReadableContext(fields: otherFields, floating: floating).padding(.top, 7)
                    }.font(.system(size: 11)).foregroundStyle(secondary)
                }
            } else if !fields.isEmpty {
                DisclosureGroup("Full context") {
                    ReadableContext(fields: fields, floating: floating).padding(.top, 7)
                }.font(.system(size: 11)).foregroundStyle(secondary)
            }
        }
    }
    private func focusCustomAnswer(_ questionID: String, using proxy: ScrollViewProxy) {
        store.replyWorkspace.highlighted[request.id] = .input(questionID)
        proxy.scrollTo(ReplyChoice.input(questionID), anchor: .center)
        answerFocused = questionID
    }
    private func approvalActions(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: floating ? 10 : 12) {
            if request.kind == "permission" {
                HStack(spacing: 10) {
                    Button("Allow once") { store.reply(session: session.id, request: request, decision: "allow") }
                        .buttonStyle(ReplyButtonStyle(primary: true, highlighted: keyboardChoice == .allowOnce))
                        .keyboardShortcut(shortcut(for: .allowOnce)).id(ReplyChoice.allowOnce)
                        .help("Up and Down choose an option. Return activates the highlighted option, including remembered scopes. Text editing keeps normal keys.")
                    denialAction
                }
                if request.supportsFeedback == true {
                    TextField("Denial instructions", text: Binding(get: { feedback }, set: { feedback = $0 }),
                              prompt: Text("Denial instructions (optional)").foregroundColor(secondary), axis: .vertical)
                        .textFieldStyle(.plain).lineLimit(1...3).font(.system(size: 12))
                        .padding(.vertical, 7)
                        .overlay(alignment: .bottom) { Rectangle().fill(feedbackFocused ? Palette.accent : secondary.opacity(0.65)).frame(height: feedbackFocused ? 2 : 1) }
                        .focused($feedbackFocused)
                    if feedback.utf16.count > 4000 {
                        Text("Keep instructions within 4,000 characters.").font(.system(size: 12)).foregroundStyle(Palette.amber)
                    }
                }
                if !(request.permissionOptions ?? []).isEmpty {
                    let horizontal = wide && (request.permissionOptions?.count ?? 0) <= 2
                    let layout = horizontal ? AnyLayout(HStackLayout(alignment: .top, spacing: 24)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    layout { ForEach(request.permissionOptions ?? []) { option in scopeAction(option) } }
                        .padding(.top, 6)
                    Text("Remembered approvals skip future prompts within their scope.")
                        .font(.system(size: 11)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                let customQuestions = request.questions.filter(\.allowFreeform)
                if customQuestions.count == 1, let question = customQuestions.first {
                    Button {
                        focusCustomAnswer(question.id, using: proxy)
                    } label: {
                        Label("Write your own answer", systemImage: "square.and.pencil")
                    }.buttonStyle(.plain).font(WorkspaceType.text(12)).foregroundStyle(Palette.accent)
                        .keyboardShortcut(shortcut(for: .input(question.id)))
                } else if !customQuestions.isEmpty {
                    Menu {
                        ForEach(customQuestions) { question in
                            Button(question.text) { focusCustomAnswer(question.id, using: proxy) }
                                .keyboardShortcut(shortcut(for: .input(question.id)))
                        }
                    } label: {
                        Label("Write your own answer", systemImage: "square.and.pencil")
                    }.menuStyle(.borderlessButton).font(WorkspaceType.text(12)).foregroundStyle(Palette.accent)
                } else {
                    Text("This request only accepts the listed choices.")
                        .font(WorkspaceType.text(11)).foregroundStyle(secondary)
                }
                Button("Send answer") { store.reply(session: session.id, request: request, decision: "answer", answers: answers) }
                    .buttonStyle(ReplyButtonStyle(primary: true, highlighted: keyboardChoice == .send))
                    .keyboardShortcut(shortcut(for: .send)).id(ReplyChoice.send)
                    .disabled(!request.accepts(decision: "answer", answers: answers))
            }
        }.disabled(store.sending.contains(request.id) || !session.connected)
    }
    private var denialAction: some View {
        Button(request.kind == "question" ? "Decline" : (denialFeedback == nil ? "Deny" : "Deny with instructions")) {
            store.reply(session: session.id, request: request, decision: "deny", feedback: denialFeedback)
        }.buttonStyle(ReplyButtonStyle(primary: false, highlighted: keyboardChoice == .deny))
            .keyboardShortcut(shortcut(for: .deny)).id(ReplyChoice.deny)
            .disabled(store.sending.contains(request.id) || !session.connected ||
                      !request.accepts(decision: "deny", answers: [:], feedback: denialFeedback))
    }
    private func scopeAction(_ option: PermissionOption) -> some View {
        let layout = floating ? AnyLayout(HStackLayout(alignment: .top, spacing: 12)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 5))
        return layout {
            Button(option.label) {
                store.reply(session: session.id, request: request, decision: "allow", permissionOptionID: option.id)
            }.buttonStyle(ReplyButtonStyle(primary: false, highlighted: keyboardChoice == .scope(option.id)))
                .keyboardShortcut(shortcut(for: .scope(option.id))).id(ReplyChoice.scope(option.id))
                .frame(maxWidth: floating ? 160 : nil, alignment: .leading)
                .help(option.label)
            Text(option.detail).font(WorkspaceType.text(11)).foregroundStyle(secondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func questionField(_ question: AgentQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.text + (question.required == false ? " (optional)" : "")).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            if question.multiple { Text("Choose any that apply").font(.system(size: 10)).foregroundStyle(secondary) }
            ForEach(question.options, id: \.self) { option in
                let selected = selections[question.id]?.contains(option.label) == true
                Button {
                    store.replyWorkspace.toggleOption(option.label, question: question, request: request)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: selected ? (question.multiple ? "checkmark.square.fill" : "largecircle.fill.circle") : (question.multiple ? "square" : "circle"))
                            .foregroundStyle(selected ? Palette.accent : secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.label).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .foregroundStyle(Palette.ink)
                                .background(selected ? Palette.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(
                                    keyboardChoice == .option(question: question.id, label: option.label) ? Palette.accent : .clear, lineWidth: 2))
                            if !option.description.isEmpty { Text(option.description).font(.system(size: 11)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true) }
                        }
                        Spacer(minLength: 0)
                    }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(keyboardChoice == .option(question: question.id, label: option.label) ? Palette.accent : Palette.ink)
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
                ), prompt: Text(question.options.isEmpty ? "Your answer" : "Type your own answer").foregroundColor(secondary),
                          axis: .vertical).textFieldStyle(.plain).font(.system(size: 13)).lineLimit(2...5)
                    .padding(.vertical, 9)
                    .accessibilityLabel(question.text)
                    .focused($answerFocused, equals: question.id)
                    .onSubmit {
                        store.reply(session: session.id, request: request, decision: "answer", answers: answers)
                    }
                    .overlay(alignment: .bottom) { Rectangle().fill(keyboardChoice == .input(question.id) ? Palette.accent : secondary.opacity(0.65)).frame(height: 1) }
                    .id(ReplyChoice.input(question.id))
            }
        }.disabled(store.sending.contains(request.id) || !session.connected)
    }
}

struct ReplyButtonStyle: ButtonStyle {
    let primary: Bool
    var highlighted: Bool?
    var destructive = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let filled = highlighted ?? primary
        configuration.label.font(WorkspaceType.text(13, strong: true))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .foregroundStyle(filled ? Palette.highlightInk : Palette.ink)
            .background(filled ? (destructive ? Palette.error : Palette.accent) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(filled ? .clear : Palette.line, lineWidth: 1))
            .opacity(!enabled ? 0.4 : (configuration.isPressed ? 0.7 : 1))
    }
}

struct FloatingView: View {
    @ObservedObject var store: Store
    let openCenter: () -> Void
    @State private var colorHovered = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let id = store.steeringSessionID {
                FloatingSteeringView(store: store, sessionID: id, openCenter: openCenter)
            } else if let item = store.activeFloatingRequest {
                let index = store.floatingRequests.firstIndex { $0.request.id == store.replyWorkspace.floatingID } ?? 0
                HStack(spacing: 10) {
                    Button {
                        store.floatingColorPickerSessionID = item.session.id
                    } label: {
                        Circle().fill(floatingColor)
                            .overlay(Circle().strokeBorder(Palette.line, lineWidth: 1))
                            .frame(width: 20, height: 20).padding(6)
                            .background(colorHovered ? Palette.raised : .clear, in: Circle())
                            .contentShape(Circle())
                    }.buttonStyle(.plain)
                        .onHover { colorHovered = $0 }
                        .accessibilityLabel("Change session color")
                        .help("Change color for \(item.session.name)")
                        .popover(isPresented: Binding(
                            get: { store.floatingColorPickerSessionID == item.session.id },
                            set: { if !$0 { store.floatingColorPickerSessionID = nil } }
                        )) {
                            SessionColorChoices(store: store, sessionID: item.session.id)
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.session.name).font(WorkspaceType.text(18, strong: true)).lineLimit(2).help(item.session.name)
                        Text("\(item.session.projectLabel) · \(agentName(item.session.agent))").font(WorkspaceType.text(11)).foregroundStyle(Palette.noticeMuted)
                    }
                    Spacer()
                    Text("\(min(index + 1, store.floatingRequests.count)) of \(store.floatingRequests.count)").font(WorkspaceType.text(11)).foregroundStyle(Palette.noticeMuted)
                }
                .padding(.bottom, 7)
                if store.automation.dangerous.contains(item.session.id) {
                    DangerousAutoYesWarning(store: store, sessionID: item.session.id)
                } else if store.automation.enabled.contains(item.session.id) { AutoYesWarning() }
                RequestEditor(store: store, session: item.session, request: item.request, floating: true).id(item.request.id)
                Divider()
                Text("↑ ↓ choose · Return selects").font(.system(size: 10)).foregroundStyle(Palette.noticeMuted)
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
                }.buttonStyle(.plain).font(WorkspaceType.text(12)).foregroundStyle(Palette.noticeMuted)
            }
        }.padding(24).background(floatingSurface).clipShape(RoundedRectangle(cornerRadius: 26))
            .foregroundStyle(Palette.ink).tint(Palette.accent)
            .onChange(of: store.activeFloatingRequest?.session.id) { _, id in
                if let pickerID = store.floatingColorPickerSessionID, pickerID != id { store.floatingColorPickerSessionID = nil }
            }
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
            ScrollView {
            VStack(alignment: .leading, spacing: 20) {
            Button("Connect agents") { store.showSetup() }
                .font(WorkspaceType.text(14, strong: true))
            VStack(alignment: .leading, spacing: 8) {
                Text("Appearance").font(WorkspaceType.text(14, strong: true))
                Picker("Appearance", selection: $store.appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }.pickerStyle(.segmented).labelsHidden()
                Text("Only changes Notify. System follows your Mac's appearance.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Divider()
            MobileSettingsView(mobile: store.mobile)
            InternetSettingsView(internet: store.internet)
            Divider()
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
            Text("History contains session labels and decisions, not answers. Conversation previews stay on this Mac unless you explicitly request an AI description; that sends a limited excerpt through the selected agent's account.")
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
            Button("Remove disconnected sessions") { store.clearDisconnected() }
            }.frame(maxWidth: .infinity, alignment: .leading)
            }.scrollIndicators(.visible)
        }.padding(28)
            .frame(width: 550, height: min(680, (NSScreen.main?.visibleFrame.height ?? 760) - 80))
            .background(Palette.background).foregroundStyle(Palette.ink).tint(Palette.accent)
    }
}
