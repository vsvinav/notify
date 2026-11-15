import Foundation

enum ResponseRenderingChecks {
    static func run() {
        let events: [(id: String, kind: String, agentID: String?)] = [
            ("main", "assistant", nil), ("child", "assistant", "worker"),
            ("empty-child", "assistant", ""), ("tool", "tool", nil),
            ("user", "user", nil), ("reasoning", "reasoning", nil), ("status", "status", nil)
        ]
        let visible = events.filter { ResponseFeed.includes(kind: $0.kind, agentID: $0.agentID) }
        precondition(visible.map(\.id) == ["main"], "Only main-agent replies belong in the response feed")
        precondition(events.map(\.id) == ["main", "child", "empty-child", "tool", "user", "reasoning", "status"],
                     "Filtering must preserve the original activity for team tracking")
        precondition(ResponseFeed.includes(kind: "assistant", agentID: "worker", target: "worker"))
        precondition(!ResponseFeed.includes(kind: "assistant", agentID: "other", target: "worker"))

        let source = "# Result\n\nA **clear** answer with `inline()`.\n\n- First\n  - Nested\n2. Next\n\n```swift\nlet x = 1\n\n  print(x)\n```\n\nDone."
        precondition(ResponseMarkdown.blocks(source) == [
            .heading(level: 1, text: "Result"),
            .paragraph("A **clear** answer with `inline()`."),
            .listItem(marker: "•", depth: 0, text: "First"),
            .listItem(marker: "•", depth: 1, text: "Nested"),
            .listItem(marker: "2.", depth: 0, text: "Next"),
            .code(language: "swift", text: "let x = 1\n\n  print(x)\n", closed: true),
            .paragraph("Done.")
        ], "Response prose and code must have distinct, readable blocks")

        precondition(ResponseMarkdown.blocks("```python\n  print('hi')") == [
            .code(language: "python", text: "  print('hi')", closed: false)
        ], "Streaming code preserves whitespace and does not invent a newline")
        precondition(ResponseMarkdown.blocks("```swift") == [
            .code(language: "swift", text: "", closed: false)
        ], "An unfinished opening fence is a code block, not visible Markdown")
        precondition(ResponseMarkdown.blocks("````md\n```swift\nx\n```\n````") == [
            .code(language: "md", text: "```swift\nx\n```\n", closed: true)
        ], "A shorter nested fence must remain literal code")
        precondition(ResponseMarkdown.blocks("~~~sh\r\nprintf 'hi'\r\n~~~\r\n") == [
            .code(language: "sh", text: "printf 'hi'\r\n", closed: true)
        ], "Copy retains original CRLF code bytes")
        precondition(ResponseMarkdown.blocks("```sh\nx\n``") == [
            .code(language: "sh", text: "x\n``", closed: false)
        ], "Partial closing fences must not discard streaming text")
        precondition(ResponseMarkdown.blocks("```sh\nx\n``` not a close\n~~~\n```") == [
            .code(language: "sh", text: "x\n``` not a close\n~~~\n", closed: true)
        ], "Only a matching fence with a whitespace-only suffix closes code")
        precondition(ResponseMarkdown.blocks("Title\n=====\n\n- Item\n  continued\n\nTail") == [
            .heading(level: 1, text: "Title"),
            .listItem(marker: "•", depth: 0, text: "Item\ncontinued"),
            .paragraph("Tail")
        ], "Setext headings and list continuations preserve hierarchy")
        precondition(ResponseMarkdown.blocks(" \n\n").isEmpty)

        let inline = ResponseMarkdown.inline("**Bold** and *soft* with `code` and [web](https://example.com).")
        precondition(String(inline.characters) == "Bold and soft with code and web.")
        precondition(inline.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        precondition(inline.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        precondition(inline.runs.contains { $0.link?.scheme == "https" })
        let unsafe = ResponseMarkdown.inline("[run](javascript:alert) [local](file:///etc/passwd) [tool](command:run)")
        precondition(unsafe.runs.allSatisfy { $0.link == nil }, "Response links must not launch local files or commands")
        precondition(String(ResponseMarkdown.inline("<script>alert('x')</script>").characters).contains("alert"))
    }
}

#if RESPONSE_RENDERING_CHECKS
@main struct ResponseRenderingCheckRunner {
    static func main() {
        ResponseRenderingChecks.run()
        print("Response rendering checks passed")
    }
}
#endif
