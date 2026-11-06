import AppKit
import SwiftUI
import XCTest
@testable import Margin

@MainActor
final class NativeFindScrollTests: XCTestCase {
    func testEditingWithFindOpenDoesNotJumpToAMatch() async throws {
        _ = NSApplication.shared
        let editor = NativeDocumentEditor()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: editor.view)
        window.contentView = host
        defer { window.close() }
        let filler = (1...300).map { "Line \($0) of plain text here." }.joined(separator: "\n\n")
        let markdown = "needle at top\n\n" + filler + "\n\nneedle at bottom\n"
        editor.open(id: "find-scroll", markdown: markdown, documentURL: nil, activate: true)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let tv = try XCTUnwrap(editor.focusView as? NSTextView)
        tv.setSelectedRange(NSRange(location: 0, length: 6))
        editor.find("open")
        try await Task.sleep(for: .milliseconds(400))

        // Go to the middle, far from both matches, and click and type there.
        let middle = (markdown as NSString).range(of: "Line 150 of").location
        tv.setSelectedRange(NSRange(location: middle, length: 0))
        tv.scrollRangeToVisible(NSRange(location: middle, length: 0))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(matchOnScreen(tv))
        tv.insertText("x", replacementRange: tv.selectedRange())
        try await Task.sleep(for: .milliseconds(900))
        // Repainting the highlights after the edit must not scroll to one.
        XCTAssertFalse(matchOnScreen(tv))

        // Next and Previous land on the far match itself, not where the
        // estimated line heights first put it.
        for step in ["next", "next", "previous"] {
            editor.find(step)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertTrue(matchOnScreen(tv), "after \(step)")
        }
    }

    private func matchOnScreen(_ tv: NSTextView) -> Bool {
        let text = tv.string as NSString
        return ["needle at top", "needle at bottom"].contains { inViewport(text.range(of: $0).location, tv) }
    }

    /// Whether `location` is in the part of the document TextKit lays out for
    /// the current scroll position.
    private func inViewport(_ location: Int, _ tv: NSTextView) -> Bool {
        guard let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager,
              let loc = tcm.location(tcm.documentRange.location, offsetBy: location) else { return false }
        let viewport = tlm.textViewportLayoutController
        viewport.layoutViewport()
        return viewport.viewportRange?.contains(loc) ?? false
    }
}
