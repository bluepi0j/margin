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

    func testWrappingCRLFSelectionInCodeKeepsLineBreaks() throws {
        let text = "first\r\nsecond"
        let (block, caret) = try XCTUnwrap(MarkdownEditing.blockSnippet("codeBlock", selection: text))
        let edit = MarkdownEditing.insertBlock(text, NSRange(location: 0, length: (text as NSString).length), block, caretOffset: caret)
        XCTAssertEqual(apply(text, edit), "```\r\nfirst\r\nsecond\r\n```\r\n")
        XCTAssertEqual(edit.selection.location, 5)
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

    func testHeadingsUseRealCRLFOffsetsAndMatchingFences() {
        let text = "# First\r\n\r\n````md\r\n```\r\n# Still code\r\n````\r\n## Last\r\n"
        let headings = MarkdownEditing.headings(text)
        XCTAssertEqual(headings.map(\.text), ["First", "Last"])
        XCTAssertEqual(headings.last?.location, (text as NSString).range(of: "## Last").location)
    }

    func testWordCount() {
        XCTAssertEqual(MarkdownEditing.wordCount("Hello, world! It's fine."), 4)
        XCTAssertEqual(MarkdownEditing.wordCount("中文字数 test"), 5)
    }

    // MARK: Review regressions

    func testListOverCRLFSelectionWithBlankLine() {
        let t = "a\r\n\r\nb"
        let e = MarkdownEditing.setLineKind(t, NSRange(location: 0, length: 6), .bullet)
        XCTAssertEqual(apply(t, e), "- a\r\n- \r\n- b")
    }

    func testItalicRoundTripsInsideBold() {
        let t = "**a**"
        let on = MarkdownEditing.toggleInline(t, NSRange(location: 2, length: 1), marker: "*")
        let both = apply(t, on)
        XCTAssertEqual(both, "***a***")
        XCTAssertEqual(apply(both, MarkdownEditing.toggleInline(both, on.selection, marker: "*")), t)
    }

    func testItalicOnASelectionWithItsBoldMarkersKeepsTheBold() {
        let t = "**a**"
        let on = MarkdownEditing.toggleInline(t, NSRange(location: 0, length: 5), marker: "*")
        let both = apply(t, on)
        XCTAssertEqual(both, "***a***")
        XCTAssertEqual(apply(both, MarkdownEditing.toggleInline(both, on.selection, marker: "*")), t)
        // Bold and italic selected with their markers: italic comes off.
        XCTAssertEqual(apply(both, MarkdownEditing.toggleInline(both, NSRange(location: 0, length: 7), marker: "*")), t)
    }

    func testInsertBlockUsesTheDocumentsLineBreaks() {
        let t = "abc\r\ndef"
        let rule = MarkdownEditing.insertBlock(t, NSRange(location: 5, length: 0), "---", caretOffset: 3)
        XCTAssertEqual(apply(t, rule), "abc\r\n\r\n---\r\n\r\ndef")
        XCTAssertEqual(rule.selection.location, 5 + 2 + 3)
        let code = MarkdownEditing.insertBlock(t, NSRange(location: 5, length: 0), "```\n\n```", caretOffset: 4)
        XCTAssertEqual(apply(t, code), "abc\r\n\r\n```\r\n\r\n```\r\n\r\ndef")
        XCTAssertEqual(code.selection.location, 5 + 2 + 5) // after "```\r\n"
    }

    func testIndentedHeadingTitleDropsTheMarker() {
        XCTAssertEqual(MarkdownEditing.headings("  ## Foo").map(\.text), ["Foo"])
        XCTAssertEqual(MarkdownEditing.headings("    # code, not a heading"), [])
    }

    func testStarBulletIsNotItalic() {
        let s = MarkdownEditing.state("* item", caret: 4)
        XCTAssertTrue(s.flags.contains("bulletList"))
        XCTAssertFalse(s.flags.contains("italic"))
    }

    func testMultiLineSelectionCoversTheChangedLines() {
        let e = MarkdownEditing.setLineKind("abc\ndef", NSRange(location: 1, length: 5), .heading(1))
        XCTAssertEqual(e.selection, NSRange(location: 0, length: 10))
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

    func testCRLFLanguageEditUsesActualOffsets() throws {
        let text = "Intro\r\n\r\n```python\r\nprint(1)\r\n```\r\n"
        let caret = (text as NSString).range(of: "print").location
        let fence = try XCTUnwrap(MarkdownEditing.codeFence(containing: caret, in: text))
        let edit = MarkdownEditing.setLanguage("swift", of: fence)
        XCTAssertEqual((text as NSString).replacingCharacters(in: edit.range, with: edit.text),
                       "Intro\r\n\r\n```swift\r\nprint(1)\r\n```\r\n")
    }
}

final class FencedBlockTests: XCTestCase {
    /// The precomputed blocks answer exactly like the scan, caret by caret.
    func testCodeInsideAFencedBlock() {
        let text = "Intro\n\n```mermaid\ngraph LR\n  A --> B\n```\n\n~~~\nopen\nto the end"
        let blocks = MarkdownEditing.fencedBlocks(in: text)
        XCTAssertEqual(blocks.map { MarkdownEditing.code(in: $0, of: text) }, ["graph LR\n  A --> B", "open\nto the end"])
        let crlf = "```mermaid\r\ngraph LR\r\n```\r\n"
        XCTAssertEqual(MarkdownEditing.code(in: MarkdownEditing.fencedBlocks(in: crlf)[0], of: crlf), "graph LR")
        let empty = "```mermaid\n```\n"
        XCTAssertEqual(MarkdownEditing.code(in: MarkdownEditing.fencedBlocks(in: empty)[0], of: empty), "")
    }

    func testFencedBlocksMatchTheScan() {
        let samples = [
            "a\n```js\ncode\n```\nb\n",
            "~~~\nx\n```\nstill\n~~~\nafter",
            "````\n```\nnested\n````\n",
            "```\nnever closed\n",
            "  ```py\r\nx = 1\r\n  ```\r\ntext\r\n",
            "``` \n```js lang\nmore\n```\n```\n",
            "    ```\nindented four is not a fence\n",
            "",
            "plain\ntext\n",
        ]
        for text in samples {
            let blocks = MarkdownEditing.fencedBlocks(in: text)
            for caret in 0...(text as NSString).length {
                XCTAssertEqual(MarkdownEditing.codeFence(containing: caret, in: blocks),
                               MarkdownEditing.codeFence(containing: caret, in: text), "\(text.debugDescription) @\(caret)")
            }
        }
    }

    /// The UTF-16 heading scan reads the same headings as before.
    func testHeadingsInFencesAndIndents() {
        let text = "# One\n```\n# not\n```\n   ## Two **b**\n    # code\n~~~~\n# no\n~~~\n# no\n~~~~\n### Three\r\n#nospace\n"
        XCTAssertEqual(MarkdownEditing.headings(text).map(\.text), ["One", "Two b", "Three"])
        XCTAssertEqual(MarkdownEditing.headings(text).map(\.location), [0, 20, (text as NSString).range(of: "### Three").location])
    }
}
