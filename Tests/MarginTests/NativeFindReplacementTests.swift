import AppKit
import SwiftUI
import XCTest
@testable import Margin

@MainActor
final class NativeFindReplacementTests: XCTestCase {
    func testReplacementSkipsItsOwnQueryAndCanResumeNavigation() async throws {
        _ = NSApplication.shared
        let editor = NativeDocumentEditor()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: editor.view)
        window.contentView = host
        defer { window.close() }
        editor.open(id: "replace-test", markdown: "cat and cat", documentURL: nil, activate: true)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        let tv = try XCTUnwrap(editor.focusView as? NSTextView)
        let scroll = try XCTUnwrap(tv.enclosingScrollView)
        let topInset = scroll.contentInsets.top
        tv.setSelectedRange(NSRange(location: 0, length: 3))
        editor.find("open")
        XCTAssertEqual(scroll.contentInsets.top, topInset + 32)
        editor.find("replace")
        XCTAssertEqual(scroll.contentInsets.top, topInset + 63)
        let controls = descendants(host)
        let replacement = try XCTUnwrap(controls.compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == "Replace" })
        let button = try XCTUnwrap(controls.compactMap { $0 as? NSButton }
            .first { $0.title == "Replace" && $0.bezelStyle == .rounded })
        replacement.stringValue = "cats"
        button.performClick(nil)
        XCTAssertEqual(tv.string, "cats and cat")
        button.performClick(nil)
        XCTAssertEqual(tv.string, "cats and cats")
        try await Task.sleep(for: .milliseconds(600))
        button.performClick(nil)
        XCTAssertEqual(tv.string, "cats and cats")
        editor.find("previous")
        button.performClick(nil)
        XCTAssertEqual(tv.string, "cats and catss")
        tv.undoManager?.undo()
        XCTAssertEqual(tv.string, "cats and cats")
        let done = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == "Done" })
        done.performClick(nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(scroll.contentInsets.top, topInset)
    }

    func testTabMovesBetweenFindAndReplace() async throws {
        _ = NSApplication.shared
        let editor = NativeDocumentEditor()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: editor.view)
        window.contentView = host
        defer { window.close() }
        editor.open(id: "tab-test", markdown: "cat and cat", documentURL: nil, activate: true)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        editor.find("replace")
        let controls = descendants(host)
        let find = try XCTUnwrap(controls.compactMap { $0 as? NSSearchField }.first)
        let replace = try XCTUnwrap(controls.compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == "Replace" })
        func editing(_ field: NSTextField) -> Bool {
            (window.firstResponder as? NSTextView)?.delegate === field
        }
        window.makeFirstResponder(find)
        (window.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertTrue(editing(replace))
        (window.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertTrue(editing(find))
        (window.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        XCTAssertTrue(editing(replace))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
