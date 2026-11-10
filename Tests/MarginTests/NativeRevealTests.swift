import AppKit
import SwiftUI
import XCTest
@testable import Margin

@MainActor
final class NativeRevealTests: XCTestCase {
    func testASearchResultOpensAtTheMatchOnItsLine() async throws {
        _ = NSApplication.shared
        let editor = NativeDocumentEditor()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: editor.view)
        window.contentView = host
        defer { window.close() }
        let text = "# Notes\n\nfirst target here\n\n- item\n- another target\n\nlast target\n"
        editor.open(id: "reveal-test", markdown: text, documentURL: nil, activate: true)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        let tv = try XCTUnwrap(editor.focusView as? NSTextView)
        let ns = text as NSString
        editor.reveal("target", line: 6)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: ns.range(of: "another target").location + 8, length: 6))
        editor.reveal("TARGET", line: 8)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: ns.range(of: "last target").location + 5, length: 6))
        // A line without it: the next match after that line.
        editor.reveal("target", line: 4)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: ns.range(of: "another target").location + 8, length: 6))
        // Nothing from that line on (the file changed since the search): the first match.
        editor.reveal("target", line: 40)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: ns.range(of: "first target").location + 6, length: 6))
    }
}
