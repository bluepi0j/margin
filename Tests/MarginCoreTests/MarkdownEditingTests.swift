import XCTest
@testable import MarginCore

final class MarkdownEditingTests: XCTestCase {
    func apply(_ text: String, _ e: MarkdownEditing.Edit) -> String {
        (text as NSString).replacingCharacters(in: e.range, with: e.text)
    }

    func testToggleBoldWrapsAndUnwraps() {
        let t = "say hello now"
        let e = MarkdownEditing.toggleInline(t, NSRange(location: 4, length: 5), marker: "**")
        let wrapped = apply(t, e)
        XCTAssertEqual(wrapped, "say **hello** now")
        XCTAssertEqual(e.selection, NSRange(location: 6, length: 5))
        let back = MarkdownEditing.toggleInline(wrapped, e.selection, marker: "**")
        XCTAssertEqual(apply(wrapped, back), t)
    }

    func testEmptySelectionInsertsPair() {
        let e = MarkdownEditing.toggleInline("ab", NSRange(location: 1, length: 0), marker: "`")
        XCTAssertEqual(apply("ab", e), "a``b")
        XCTAssertEqual(e.selection.location, 2)
    }

    func testHeadingToggle() {
        let t = "Title\nbody"
        let e = MarkdownEditing.setLineKind(t, NSRange(location: 2, length: 0), .heading(2))
        let h = apply(t, e)
        XCTAssertEqual(h, "## Title\nbody")
        XCTAssertEqual(e.selection.location, 5)
        // Same level again turns it back into a paragraph.
        XCTAssertEqual(apply(h, MarkdownEditing.setLineKind(h, NSRange(location: 4, length: 0), .heading(2))), t)
        // Another level replaces it.
        XCTAssertEqual(apply(h, MarkdownEditing.setLineKind(h, NSRange(location: 4, length: 0), .heading(1))), "# Title\nbody")
    }

    func testHeadingOnEmptyLastLine() {
        let t = "text\n"
        let e = MarkdownEditing.setLineKind(t, NSRange(location: 5, length: 0), .heading(2))
        XCTAssertEqual(apply(t, e), "text\n## ")
        XCTAssertEqual(e.selection.location, 8)
    }

    func testListsOverSeveralLines() {
        let t = "a\nb\nc"
        let all = NSRange(location: 0, length: 5)
        XCTAssertEqual(apply(t, MarkdownEditing.setLineKind(t, all, .ordered)), "1. a\n2. b\n3. c")
        let bullets = apply(t, MarkdownEditing.setLineKind(t, all, .bullet))
        XCTAssertEqual(bullets, "- a\n- b\n- c")
        XCTAssertEqual(apply(bullets, MarkdownEditing.setLineKind(bullets, NSRange(location: 0, length: 11), .task)), "- [ ] a\n- [ ] b\n- [ ] c")
    }

    func testInsertBlockOnOwnLines() {
        let t = "abc"
        let e = MarkdownEditing.insertBlock(t, NSRange(location: 3, length: 0), "---", caretOffset: 3)
        XCTAssertEqual(apply(t, e), "abc\n\n---\n")
    }

    func testBlockAfterListGetsBlankLine() {
        let t = "- item\n"
        let e = MarkdownEditing.insertBlock(t, NSRange(location: 7, length: 0), "---", caretOffset: 3)
        XCTAssertEqual(apply(t, e), "- item\n\n---\n")
        let top = MarkdownEditing.insertBlock("", NSRange(location: 0, length: 0), "---", caretOffset: 3)
        XCTAssertEqual(apply("", top), "---\n")
    }

    func testState() {
        let t = "## Head\n- item **bo|ld**"
        let caret = (t as NSString).range(of: "|").location
        let clean = t.replacingOccurrences(of: "|", with: "")
        let s = MarkdownEditing.state(clean, caret: caret)
        XCTAssertTrue(s.flags.contains("bulletList"))
        XCTAssertTrue(s.flags.contains("bold"))
        XCTAssertFalse(s.flags.contains("italic"))
        XCTAssertEqual(MarkdownEditing.state(clean, caret: 3).heading, 2)
    }

    func testHeadingsSkipCode() {
        let t = "# A\ntext\n```\n# not\n```\n## B **x**\n"
        let h = MarkdownEditing.headings(t)
        XCTAssertEqual(h.map(\.text), ["A", "B x"])
        XCTAssertEqual(h.map(\.level), [1, 2])
        XCTAssertEqual(h[1].location, (t as NSString).range(of: "## B").location)
    }

    func testMapLocationAcrossExternalEdit() {
        let old = "- [ ] Dune\nTyped here"
        let new = "- [x] Dune (checked)\nTyped here"
        let caret = (old as NSString).length            // end of document
        XCTAssertEqual(MarkdownEditing.mapLocation(caret, from: old, to: new), (new as NSString).length)
        XCTAssertEqual(MarkdownEditing.mapLocation(2, from: old, to: new), 2)  // before the change
    }

    func testWordCount() {
        XCTAssertEqual(MarkdownEditing.wordCount("Hello, world! It's fine."), 4)
        XCTAssertEqual(MarkdownEditing.wordCount("中文字数 test"), 5)
    }
}

final class CodeFenceTests: XCTestCase {
    private let doc = "Intro\n\n```python title=\"x.py\"\nprint(1)\n```\n\nAfter\n\n~~~\nplain\n~~~\n"

    private func at(_ needle: String) -> Int { (doc as NSString).range(of: needle).location }

    func testCaretInsideBodyFindsFence() {
        let fence = MarkdownEditing.codeFence(containing: at("print"), in: doc)
        XCTAssertEqual(fence?.language, "python")
        XCTAssertEqual(fence.map { (doc as NSString).substring(with: $0.openingLine) }, "```python title=\"x.py\"")
    }

    func testCaretOnFenceLinesCounts() {
        XCTAssertEqual(MarkdownEditing.codeFence(containing: at("```python"), in: doc)?.language, "python")
        XCTAssertEqual(MarkdownEditing.codeFence(containing: at("```\n\nAfter") + 2, in: doc)?.language, "python")
    }

    func testCaretOutsideIsNil() {
        XCTAssertNil(MarkdownEditing.codeFence(containing: at("Intro"), in: doc))
        XCTAssertNil(MarkdownEditing.codeFence(containing: at("After"), in: doc))
    }

    func testTildeFenceWithoutLanguage() {
        let fence = MarkdownEditing.codeFence(containing: at("plain"), in: doc)
        XCTAssertEqual(fence?.language, "")
        XCTAssertEqual(fence?.languageRange.length, 0)
        XCTAssertEqual(fence?.languageRange.location, at("~~~\nplain") + 3)
    }

    func testSetLanguageReplacesOnlyTheWord() {
        let fence = MarkdownEditing.codeFence(containing: at("print"), in: doc)!
        let edit = MarkdownEditing.setLanguage("swift", of: fence)
        let result = (doc as NSString).replacingCharacters(in: edit.range, with: edit.text)
        XCTAssertTrue(result.contains("```swift title=\"x.py\"\nprint(1)"))
    }

    func testUnclosedFenceRunsToEnd() {
        let text = "a\n```js\nlet x"
        XCTAssertEqual(MarkdownEditing.codeFence(containing: 12, in: text)?.language, "js")
    }
}
