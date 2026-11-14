import Foundation
import CoreFoundation

public struct ContextField: Identifiable {
    public let id: Int
    public let label: String
    public let value: String

    public enum Presentation { case text, code, diff, warning }
    private var key: String {
        label.components(separatedBy: " / ").last(where: { Int($0) == nil }) ?? label
    }
    public var presentation: Presentation {
        if ["Warning", "Hook Message", "Request Sandbox Bypass Reason"].contains(key) ||
            (["Request Sandbox Bypass", "Request Sandbox Permissive", "Managed Approval Required"].contains(key) && value == "Yes") {
            return .warning
        }
        if ["Diff", "Patch", "Unified Diff"].contains(key) { return .diff }
        if ["Command", "Full Command Text", "Old String", "New String", "New File Contents", "Content", "Before", "After"].contains(key) {
            return .code
        }
        return .text
    }
    public var displayLabel: String {
        let names = ["Full Command Text": "Command", "File Name": "File", "File Path": "File",
                     "Old String": "Text to replace", "New String": "Replacement text", "New File Contents": "New content",
                     "Diff": "Proposed diff", "Intention": "Supplied reason", "Decision Reason": "Permission reason",
                     "Request Sandbox Bypass": "Run outside the sandbox", "Request Sandbox Permissive": "Permissive sandbox retry",
                     "Request Sandbox Bypass Reason": "Sandbox warning", "Managed Approval Required": "Managed approval required"]
        let parts = label.components(separatedBy: " / ")
        guard parts.last == key, let name = names[key] else { return label }
        return (parts.dropLast() + [name]).joined(separator: " / ")
    }
    public var isDecisionDetail: Bool { priority < 100 }
    fileprivate var priority: Int {
        if presentation == .warning { return 0 }
        if ["Command", "Full Command Text"].contains(key) { return 1 }
        if ["File Name", "File Path", "Path", "Paths", "Cwd", "Working Directory", "Url"].contains(key) { return 2 }
        if presentation == .code || presentation == .diff { return 3 }
        if ["Intention", "Reason", "Decision Reason"].contains(key) { return 4 }
        if ["Tool Name", "Server Name"].contains(key) { return 5 }
        if ["Args", "Arguments", "Input"].contains(label.components(separatedBy: " / ").first ?? "") { return 6 }
        return 100
    }
}

public enum RequestContext {
    public static func fields(from text: String, isQuestion: Bool = false) -> [ContextField] {
        guard !text.isEmpty else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else {
            if !isQuestion, let boundary = text.range(of: "\n\n{"),
               let object = try? JSONSerialization.jsonObject(with: Data(text[text.index(before: boundary.upperBound)...].utf8)) as? [String: Any] {
                let reason = String(text[..<boundary.lowerBound])
                var combined = object
                combined["decisionReason"] = reason
                if let data = try? JSONSerialization.data(withJSONObject: combined),
                   let structured = String(data: data, encoding: .utf8) {
                    return fields(from: structured)
                }
            }
            return [ContextField(id: 0, label: "", value: text)]
        }
        if isQuestion, let schema = json as? [String: Any], schema["properties"] is [String: Any] {
            return (schema["description"] as? String).map { [ContextField(id: 0, label: "", value: $0)] } ?? []
        }
        var result: [ContextField] = []
        func label(_ key: String) -> String {
            key.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
                .replacingOccurrences(of: "_", with: " ").capitalized
        }
        func append(_ value: Any, path: [String]) {
            if let object = value as? [String: Any], !object.isEmpty {
                for key in object.keys.sorted() { append(object[key]!, path: path + [label(key)]) }
            } else if let array = value as? [Any], !array.isEmpty {
                for (index, entry) in array.enumerated() { append(entry, path: path + ["\(index + 1)"]) }
            } else {
                let text: String
                if let string = value as? String { text = string }
                else if let number = value as? NSNumber {
                    text = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "Yes" : "No") : number.stringValue
                } else { text = value is NSNull ? "Not provided" : "None" }
                result.append(ContextField(id: result.count, label: path.joined(separator: " / "), value: text))
            }
        }
        append(json, path: [])
        return result.sorted { $0.priority == $1.priority ? $0.id < $1.id : $0.priority < $1.priority }
    }
}
