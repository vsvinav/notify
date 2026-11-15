import Foundation

enum ResponseFeed {
    static func includes(kind: String, agentID: String?) -> Bool {
        kind == "assistant" && agentID == nil
    }
}

enum ResponseBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case listItem(marker: String, depth: Int, text: String)
    case code(language: String, text: String, closed: Bool)
}

enum ResponseMarkdown {
    static func blocks(_ source: String) -> [ResponseBlock] {
        let lines = source.components(separatedBy: "\n")
        var result: [ResponseBlock] = []
        var paragraph: [String] = []
        var fence: (marker: Character, count: Int, language: String)?
        var code = ""
        var continuesList = false

        func flushParagraph() {
            if !paragraph.isEmpty {
                result.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }

        for (index, original) in lines.enumerated() {
            let line = original.hasSuffix("\r") ? String(original.dropLast()) : original
            let raw = original + (index < lines.count - 1 ? "\n" : "")
            let indent = line.prefix(while: { $0 == " " }).count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                let markerCount = trimmed.prefix(while: { $0 == open.marker }).count
                if indent <= 3 && markerCount >= open.count &&
                    trimmed.dropFirst(markerCount).trimmingCharacters(in: .whitespaces).isEmpty {
                    result.append(.code(language: open.language, text: code, closed: true))
                    fence = nil
                    code = ""
                } else {
                    code += raw
                }
                continue
            }
            if indent <= 3, let marker = trimmed.first, marker == "`" || marker == "~" {
                let count = trimmed.prefix(while: { $0 == marker }).count
                let info = trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces)
                if count >= 3 && (marker != "`" || !info.contains("`")) {
                    flushParagraph()
                    fence = (marker, count, String(info.split(whereSeparator: \.isWhitespace).first ?? ""))
                    continuesList = false
                    continue
                }
            }
            if trimmed.isEmpty {
                flushParagraph()
                continuesList = false
                continue
            }
            if indent <= 3, !paragraph.isEmpty,
               trimmed.allSatisfy({ $0 == "=" }) || trimmed.allSatisfy({ $0 == "-" }) {
                result.append(.heading(level: trimmed.first == "=" ? 1 : 2, text: paragraph.joined(separator: "\n")))
                paragraph.removeAll()
                continuesList = false
                continue
            }
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            if indent <= 3 && (1...6).contains(hashes),
               trimmed.count == hashes || trimmed.dropFirst(hashes).first?.isWhitespace == true {
                flushParagraph()
                let text = String(trimmed.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
                result.append(.heading(level: hashes, text: text))
                continuesList = false
                continue
            }
            if let marker = listMarker(trimmed) {
                flushParagraph()
                result.append(.listItem(marker: marker.label, depth: min(indent / 2, 6),
                                        text: String(trimmed.dropFirst(marker.length)).trimmingCharacters(in: .whitespaces)))
                continuesList = true
                continue
            }
            if continuesList && indent > 0, let last = result.last,
               case let .listItem(marker, depth, text) = last {
                result[result.count - 1] = .listItem(marker: marker, depth: depth, text: text + "\n" + trimmed)
                continue
            }
            continuesList = false
            paragraph.append(line)
        }
        if let fence { result.append(.code(language: fence.language, text: code, closed: false)) }
        flushParagraph()
        return result
    }

    static func inline(_ source: String) -> AttributedString {
        var text = (try? AttributedString(markdown: source, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible
        ))) ?? AttributedString(source)
        for run in text.runs {
            if let link = run.link, !["https", "http", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                text[run.range].link = nil
            }
        }
        return text
    }

    private static func listMarker(_ text: String) -> (label: String, length: Int)? {
        if let first = text.first, ["-", "*", "+"].contains(first),
           text.dropFirst().first?.isWhitespace == true {
            return ("•", 1)
        }
        let digits = text.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let tail = text.dropFirst(digits.count)
        guard let separator = tail.first, separator == "." || separator == ")",
              tail.dropFirst().first?.isWhitespace == true else { return nil }
        return (String(digits) + String(separator), digits.count + 1)
    }
}
