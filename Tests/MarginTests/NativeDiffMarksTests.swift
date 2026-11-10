import AppKit
import SwiftUI
import XCTest
@testable import Margin

@MainActor
final class NativeDiffMarksTests: XCTestCase {
    /// Ranges carrying the "changed word" background.
    private func wordMarks(_ tv: NSTextView) -> [NSRange] {
        var out: [NSRange] = []
        guard let storage = tv.textStorage else { return out }
        storage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let color = value as? NSColor, color == NativeDiffDecorator.addedWordColor { out.append(range) }
        }
        return out
    }

    private func makeEditor(_ markdown: String, base: String) async throws -> (NativeDocumentEditor, NSTextView, NSWindow) {
        _ = NSApplication.shared
        let editor = NativeDocumentEditor()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: editor.view)
        window.contentView = host
        editor.open(id: "diff-test", markdown: markdown, documentURL: nil, activate: true)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        let tv = try XCTUnwrap(editor.focusView as? NSTextView)
        editor.setDiffBase(id: "diff-test", base: base)
        try await Task.sleep(for: .milliseconds(100))
        return (editor, tv, window)
    }

    func testTypingKeepsAWordMarkOnItsWord() async throws {
        let (_, tv, window) = try await makeEditor("The quick red fox jumps over the lazy dog.\n\nEnd.\n",
                                                   base: "The quick brown fox jumps over the lazy dog.\n\nEnd.\n")
        defer { window.close() }
        XCTAssertEqual(wordMarks(tv), [NSRange(location: 10, length: 3)])
        tv.insertText("X", replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(50))
        // Before the debounced re-diff: the mark moved along with "red".
        XCTAssertEqual(wordMarks(tv), [NSRange(location: 11, length: 3)])
        // After it: the typed-into word counts as changed too.
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(wordMarks(tv), [NSRange(location: 0, length: 4), NSRange(location: 11, length: 3)])
    }

    func testReloadingTextOfTheSameLengthKeepsTheMarks() async throws {
        let (editor, tv, window) = try await makeEditor("The quick red fox jumps over the lazy dog.\n\nEnd.\n",
                                                        base: "The quick brown fox jumps over the lazy dog.\n\nEnd.\n")
        defer { window.close() }
        XCTAssertEqual(wordMarks(tv), [NSRange(location: 10, length: 3)])
        // Another program changed one character: same length, the whole text is replaced.
        editor.reload(id: "diff-test", markdown: "The quick red fox jumps over the lazy cat.\n\nEnd.\n")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(tv.string, "The quick red fox jumps over the lazy cat.\n\nEnd.\n")
        tv.setSelectedRange(NSRange(location: 44, length: 0))
        tv.insertText("!", replacementRange: NSRange(location: 47, length: 0))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(wordMarks(tv).contains { $0.location == 0 }, "marks: \(wordMarks(tv))")
    }
}
