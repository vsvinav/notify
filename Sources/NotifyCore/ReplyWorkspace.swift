import Foundation

public enum ReplyChoice: Hashable {
    case allowOnce, scope(String), deny, send
    case option(question: String, label: String)
    case input(String)
}

public extension AgentRequest {
    var replyChoices: [ReplyChoice] {
        if kind == "permission" {
            return [.allowOnce] + (permissionOptions ?? []).map { .scope($0.id) } + [.deny]
        }
        return questions.flatMap { question in
            question.options.map { ReplyChoice.option(question: question.id, label: $0.label) }
                + (question.allowFreeform ? [.input(question.id)] : [])
        } + [.send, .deny]
    }
}

public struct ReplyDraft {
    public var selections: [String: [String]]
    public var freeText: [String: String]
    public var feedback = ""
    public init(selections: [String: [String]] = [:], freeText: [String: String] = [:]) {
        self.selections = selections
        self.freeText = freeText
    }
    public func answers(for request: AgentRequest) -> [String: [String]] {
        var result = selections
        for question in request.questions {
            if question.multiple && question.minimumSelections == 0 && result[question.id] == nil { result[question.id] = [] }
            if let text = freeText[question.id], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result[question.id] = question.multiple ? (selections[question.id] ?? []) + [text] : [text]
            }
        }
        return result
    }
}

public struct ReplyWorkspace {
    public var drafts: [String: ReplyDraft] = [:]
    public var highlighted: [String: ReplyChoice] = [:]
    public private(set) var floatingID: String?
    public init() {}
    public func choice(for request: AgentRequest) -> ReplyChoice {
        let choices = request.replyChoices
        if let selected = highlighted[request.id], choices.contains(selected) { return selected }
        return choices[0]
    }
    public mutating func moveChoice(_ direction: Int, for request: AgentRequest) {
        let choices = request.replyChoices
        let index = choices.firstIndex(of: choice(for: request)) ?? 0
        highlighted[request.id] = choices[(index + (direction < 0 ? choices.count - 1 : 1)) % choices.count]
    }
    public mutating func toggleOption(_ label: String, question: AgentQuestion, request: AgentRequest) {
        highlighted[request.id] = .option(question: question.id, label: label)
        var draft = drafts[request.id] ?? ReplyDraft()
        var values = draft.selections[question.id] ?? []
        if values.contains(label) { values.removeAll { $0 == label } }
        else if question.multiple { values.append(label) }
        else { values = [label]; draft.freeText[question.id] = "" }
        draft.selections[question.id] = values
        drafts[request.id] = draft
        if !question.multiple && request.questions.count == 1 && request.accepts(decision: "answer", answers: draft.answers(for: request)) {
            highlighted[request.id] = .send
        }
    }
    public mutating func update(requestIDs: [String]) {
        // Keep the preferred request while a disconnected peer incrementally replays its queue.
        if floatingID == nil { floatingID = requestIDs.first }
    }
    public mutating func next(requestIDs: [String]) {
        guard !requestIDs.isEmpty else { floatingID = nil; return }
        let index = floatingID.flatMap { requestIDs.firstIndex(of: $0) } ?? -1
        floatingID = requestIDs[(index + 1) % requestIDs.count]
    }
    public mutating func resolve(_ id: String) {
        drafts.removeValue(forKey: id)
        highlighted.removeValue(forKey: id)
        if floatingID == id { floatingID = nil }
    }
}
