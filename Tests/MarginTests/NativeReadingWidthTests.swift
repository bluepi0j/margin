import AppKit
import SwiftUI
import XCTest
@testable import MarkdownEngine

/// Settings › Line width reaches the native editor as the engine's
/// `readingWidth`. The engine only applied it when the view was made; the
/// Margin patch in NativeTextViewWrapper.updateNSView re-applies it (see
/// Vendor/README.md).
@MainActor
final class NativeReadingWidthTests: XCTestCase {
    func testChangingReadingWidthRewrapsTheColumn() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let text = String(repeating: "words that wrap ", count: 200)
        func wrapper(width: CGFloat) -> NativeTextViewWrapper {
            NativeTextViewWrapper(text: .constant(text), configuration: MarkdownEditorConfiguration(readingWidth: width))
        }
        let host = NSHostingView(rootView: wrapper(width: 600))
        host.frame = NSRect(x: 0, y: 0, width: 1400, height: 600)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let textView = try XCTUnwrap(Self.textView(in: host))
        XCTAssertEqual(textView.textContainer?.size.width, 600)
        XCTAssertEqual(textView.frame.width, textView.readingColumnWidth)

        host.rootView = wrapper(width: 900)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(textView.configuration.readingWidth, 900)
        XCTAssertEqual(textView.textContainer?.size.width, 900)
        XCTAssertEqual(textView.frame.width, textView.readingColumnWidth)
    }

    private static func textView(in view: NSView) -> NativeTextView? {
        if let tv = view as? NativeTextView { return tv }
        for sub in view.subviews { if let tv = textView(in: sub) { return tv } }
        return nil
    }
}
