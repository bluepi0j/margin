import AppKit
import XCTest
@testable import MarkdownEngine

@MainActor
final class NativePasteTests: XCTestCase {
    func testPlainTextAndInternalMarkdownPastePreserveWhitespace() async {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        // Exercise the real paste path without leaving changes to the user's clipboard.
        let original = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            board.clearContents()
            board.writeObjects(original.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            })
        }
        let pasted = "    indented\n\n\n    code  \n"
        for type in [NSPasteboard.PasteboardType.string, MarkdownPasteboardWriter.markdownType] {
            board.clearContents()
            board.setString(pasted, forType: type)
            let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            view.isRichText = false
            view.string = ""
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.paste(nil)
            XCTAssertEqual(view.string, pasted, "paste type: \(type.rawValue)")
        }
    }
}
