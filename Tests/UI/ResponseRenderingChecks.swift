import Foundation
#if !RESPONSE_RENDERING_CHECKS
import AppKit
import SwiftUI
import NotifyCore
import Vision
#endif

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

        let table = "| Check | Result |\n| :--- | ---: |\n| **Build** | `passed` |\nAfter the table."
        precondition(ResponseMarkdown.blocks(table) == [
            .table(headers: ["Check", "Result"], alignments: [.leading, .trailing],
                   rows: [["**Build**", "`passed`"]]),
            .paragraph("After the table.")
        ],
                     "A Markdown table must be distinct from following prose")
        precondition(ResponseMarkdown.blocks("> Important\n> Keep the key.\nNext paragraph.") == [
            .quote("Important\nKeep the key."), .paragraph("Next paragraph.")
        ],
                     "Quoted advice must stay distinct from unquoted prose")
        precondition(ResponseMarkdown.blocks("Before\n\n- - -\n\nAfter") == [
            .paragraph("Before"), .rule, .paragraph("After")
        ],
                     "A thematic break is not literal Markdown punctuation")
        precondition(ResponseMarkdown.blocks("Key | Meaning\n:---: | ---\n`a\\|b` | **or**\nshort |\n") == [
            .table(headers: ["Key", "Meaning"], alignments: [.center, .leading],
                   rows: [["`a|b`", "**or**"], ["short", ""]])
        ], "Escaped pipes, optional edge pipes and empty cells preserve table contents")
        precondition(ResponseMarkdown.blocks("| One |\n| --- |\n| extra | must survive |\n") == [
            .table(headers: ["One"], alignments: [.leading], rows: []),
            .paragraph("| extra | must survive |")
        ], "Unsupported extra cells must never silently discard response text")
        precondition(ResponseMarkdown.blocks("| One | Two |\n| --- | nope |\n") == [
            .paragraph("| One | Two |\n| --- | nope |")
        ], "Incomplete streamed table separators remain readable source")
        let wideHeader = Array(repeating: "Column", count: 17).joined(separator: " | ")
        let wideRule = Array(repeating: "---", count: 17).joined(separator: " | ")
        precondition(ResponseMarkdown.blocks(wideHeader + "\n" + wideRule) == [
            .paragraph(wideHeader + "\n" + wideRule)
        ], "Unusually wide tables retain all their source instead of expanding native layout without a bound")
        precondition(ResponseMarkdown.blocks("```md\n> literal\n| a | b |\n| --- | --- |\n***\n```\n") == [
            .code(language: "md", text: "> literal\n| a | b |\n| --- | --- |\n***\n", closed: true)
        ], "Markdown-looking code must remain byte-exact code")

        let inline = ResponseMarkdown.inline("**Bold** and *soft* with `code` and [web](https://example.com).")
        precondition(String(inline.characters) == "Bold and soft with code and web.")
        precondition(inline.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        precondition(inline.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        precondition(inline.runs.contains { $0.link?.scheme == "https" })
        let unsafe = ResponseMarkdown.inline("[run](javascript:alert) [local](file:///etc/passwd) [tool](command:run)")
        precondition(unsafe.runs.allSatisfy { $0.link == nil }, "Response links must not launch local files or commands")
        precondition(String(ResponseMarkdown.inline("<script>alert('x')</script>").characters).contains("alert"))
    }

    #if !RESPONSE_RENDERING_CHECKS
    @MainActor static func captureOffscreen() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: ".build/response-rendering-captures", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let source = """
        # A clearer response

        A **bold result**, *emphasis*, and `inline_code`.

        > Important
        > Keep the original key when updating.

        | Check | Result | Details that stay reachable |
        | :--- | ---: | --- |
        | **Build** | `passed` | The full explanation wraps inside its column without shrinking the body text. |
        | Retry | deferred | Waiting for the next eligible delivery window. |

        After the table.

        ---

        - First item
          - Nested item

        ```swift
        let message = "A long code line stays selectable and scrolls horizontally rather than clipping the conversation."
          print(message)
        ```

        End of response.
        """
        let entry = try JSONDecoder().decode(ActivityEntry.self, from: JSONSerialization.data(withJSONObject: [
            "id": "markdown-fixture", "kind": "assistant", "title": "Example response",
            "detail": source, "status": "complete", "timestamp": "2026-01-01T00:00:00Z"
        ]))
        for dark in [false, true] {
            for width in [420.0, 760.0] {
                let host = NSHostingView(rootView: ActivityRow(entry: entry).padding(20)
                    .frame(width: width, height: 640, alignment: .topLeading)
                    .background(Palette.background)
                    .environment(\.colorScheme, dark ? .dark : .light))
                host.sizingOptions = []
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 640)
                // Native scroll document geometry requires a window, but it never needs to be shown.
                let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                defer { window.contentView = nil; window.close() }
                for _ in 0..<4 {
                    host.layoutSubtreeIfNeeded()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
                func scrollViews(in view: NSView) -> [NSScrollView] {
                    ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
                }
                let horizontal = scrollViews(in: host).filter {
                    ($0.documentView?.frame.width ?? 0) > $0.contentSize.width
                }
                precondition(horizontal.count >= (width == 420 ? 2 : 1),
                             "Wide table/code scroll inspection: \(scrollViews(in: host).map { ($0.frame.width, $0.contentSize.width, $0.documentView?.frame.width ?? 0) })")
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let file = output.appendingPathComponent("markdown-\(dark ? "dark" : "light")-\(Int(width)).png")
                try bitmap.representation(using: .png, properties: [:])!.write(to: file)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([request])
                let text = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
                for expected in ["Important", "Build", "passed", "After the table.", "End of response."] {
                    precondition(text.contains(expected), "Offscreen Markdown must show \(expected) at width \(width)")
                }
                for scroll in horizontal {
                    scroll.contentView.scroll(to: NSPoint(
                        x: scroll.documentView!.frame.width - scroll.contentSize.width,
                        y: scroll.contentView.bounds.origin.y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([request])
                let scrolled = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
                precondition(scrolled.contains("reachable") && scrolled.contains("conversation"),
                             "Horizontal scrolling must reveal the final table column and the end of long code")
            }
        }
        precondition(NSApp.windows.allSatisfy { !$0.isVisible }, "Rendering checks must not display or activate a window")
        print("Offscreen native Markdown captures and horizontal scrolling passed in both themes and widths; no visible windows or live sessions used")
    }
    #endif
}

#if RESPONSE_RENDERING_CHECKS
@main struct ResponseRenderingCheckRunner {
    static func main() {
        ResponseRenderingChecks.run()
        print("Response rendering checks passed")
    }
}
#endif
