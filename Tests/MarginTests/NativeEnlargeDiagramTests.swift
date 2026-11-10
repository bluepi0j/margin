import AppKit
import SwiftUI
import XCTest
@testable import Margin

@MainActor
final class NativeEnlargeDiagramTests: XCTestCase {
    func testEnlargeAsksForTheDiagramTheCaretIsIn() async throws {
        _ = NSApplication.shared
        let editor = NativeDocumentEditor()
        var asked: [String] = []
        editor.onEvent = { if case .openDiagram(let code) = $0 { asked.append(code) } }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: editor.view)
        window.contentView = host
        defer { window.close() }
        let text = "Intro\n\n```mermaid\ngraph LR\n  A[Idea] --> B[Draft]\n```\n\nAfter\n\n```mermaid\ngraph TD\n  X --> Y\n```\n"
        editor.open(id: "enlarge-test", markdown: text, documentURL: nil, activate: true)
        host.layoutSubtreeIfNeeded()
        // The diagram buttons come with the outline, 0.25 s after the text: wait well past it.
        try await Task.sleep(for: .milliseconds(700))
        let tv = try XCTUnwrap(editor.focusView as? NSTextView)
        // Outside a diagram there is nothing to enlarge.
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        editor.enlargeDiagram()
        XCTAssertEqual(asked, [])
        tv.setSelectedRange(NSRange(location: (text as NSString).range(of: "A[Idea]").location, length: 0))
        editor.enlargeDiagram()
        tv.setSelectedRange(NSRange(location: (text as NSString).range(of: "X -->").location, length: 0))
        editor.enlargeDiagram()
        XCTAssertEqual(asked, ["graph LR\n  A[Idea] --> B[Draft]", "graph TD\n  X --> Y"])

        // Each diagram drawn as a picture has its button; the one being edited has the label.
        let buttons = descendants(host).compactMap { $0 as? NSButton }.filter { $0.toolTip == "Open the diagram in its own window" && !$0.isHidden }
        XCTAssertEqual(buttons.count, 1)
        asked = []
        buttons.first?.performClick(nil)
        XCTAssertEqual(asked, ["graph LR\n  A[Idea] --> B[Draft]"])
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
