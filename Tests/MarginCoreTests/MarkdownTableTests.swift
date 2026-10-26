import XCTest
@testable import MarginCore

final class MarkdownTableTests: XCTestCase {
    private let doc = "Intro\n\n| Name | Age |\n|---|--:|\n| Ada | 36 |\n| 林纳斯 | 54 |\n\nAfter\n"

    private func at(_ needle: String) -> Int { (doc as NSString).range(of: needle).location }

    private func apply(_ r: (edit: MarkdownEditing.Edit, caret: Int)) -> String {
        (doc as NSString).replacingCharacters(in: r.edit.range, with: r.edit.text)
    }

    func testFindsTableAndCaretCell() {
        let t = MarkdownTable.at(at("36"), in: doc)
        XCTAssertEqual(t?.rows, [["Name", "Age"], ["Ada", "36"], ["林纳斯", "54"]])
        XCTAssertEqual(t?.alignments, [.none, .right])
        XCTAssertEqual(t?.caretRow, 1)
        XCTAssertEqual(t?.caretColumn, 1)
        XCTAssertEqual(t.map { (doc as NSString).substring(with: $0.range) }, "| Name | Age |\n|---|--:|\n| Ada | 36 |\n| 林纳斯 | 54 |")
    }

    func testOutsideIsNil() {
        XCTAssertNil(MarkdownTable.at(at("Intro"), in: doc))
        XCTAssertNil(MarkdownTable.at(at("After"), in: doc))
        XCTAssertNil(MarkdownTable.at(0, in: "| just a line with a pipe |\n"))
    }

    func testCodeExampleIsNotAnEditableTable() {
        let text = "```markdown\n| A | B |\n| --- | --- |\n| 1 | 2 |\n```\n"
        XCTAssertNil(MarkdownTable.at((text as NSString).range(of: "| 1").location, in: text))
    }

    func testTidyAlignsColumnsCountingWideCharacters() {
        let out = apply(MarkdownTable.at(at("Ada"), in: doc)!.applying(.tidy))
        XCTAssertTrue(out.contains("""
        | Name   | Age |
        | ------ | --: |
        | Ada    | 36  |
        | 林纳斯 | 54  |
        """), out)
    }

    func testAddRowBelowPutsCaretInNewRow() {
        let r = MarkdownTable.at(at("Ada"), in: doc)!.applying(.addRowBelow)
        let out = apply(r)
        let rows = MarkdownTable.at(r.caret, in: out)!
        XCTAssertEqual(rows.rows.count, 4)
        XCTAssertEqual(rows.rows[2], ["", ""])
        XCTAssertEqual(rows.caretRow, 2)
        XCTAssertEqual(rows.caretColumn, 0)
    }

    func testAddRowAboveHeaderGoesBelowIt() {
        let r = MarkdownTable.at(at("Name"), in: doc)!.applying(.addRowAbove)
        XCTAssertEqual(MarkdownTable.at(r.caret, in: apply(r))?.rows[1], ["", ""])
    }

    func testAddAndDeleteColumn() {
        let added = MarkdownTable.at(at("Age"), in: doc)!.applying(.addColumnRight)
        let wider = MarkdownTable.at(added.caret, in: apply(added))!
        XCTAssertEqual(wider.rows[0], ["Name", "Age", ""])
        XCTAssertEqual(wider.alignments, [.none, .right, .none])
        XCTAssertEqual(wider.caretColumn, 2)

        let removed = MarkdownTable.at(at("Name"), in: doc)!.applying(.deleteColumn)
        XCTAssertEqual(MarkdownTable.at(removed.caret, in: apply(removed))?.rows, [["Age"], ["36"], ["54"]])
    }

    func testDeleteRowKeepsHeader() {
        let r = MarkdownTable.at(at("Ada"), in: doc)!.applying(.deleteRow)
        XCTAssertEqual(MarkdownTable.at(r.caret, in: apply(r))?.rows, [["Name", "Age"], ["林纳斯", "54"]])
        let header = MarkdownTable.at(at("Name"), in: doc)!.applying(.deleteRow)
        XCTAssertEqual(MarkdownTable.at(header.caret, in: apply(header))?.rows.count, 3)
    }

    func testTabMovesThroughCellsAndAddsRowAtEnd() {
        let next = MarkdownTable.at(at("Ada"), in: doc)!.movingToCell(forward: true)
        let t = MarkdownTable.at(next.caret, in: apply(next))!
        XCTAssertEqual([t.caretRow, t.caretColumn], [1, 1])
        XCTAssertEqual((apply(next) as NSString).substring(with: next.edit.selection), "36")   // typing replaces the cell

        let end = MarkdownTable.at(at("54"), in: doc)!.movingToCell(forward: true)
        let grown = MarkdownTable.at(end.caret, in: apply(end))!
        XCTAssertEqual(grown.rows.count, 4)
        XCTAssertEqual([grown.caretRow, grown.caretColumn], [3, 0])

        let back = MarkdownTable.at(at("Ada"), in: doc)!.movingToCell(forward: false)
        let prev = MarkdownTable.at(back.caret, in: apply(back))!
        XCTAssertEqual([prev.caretRow, prev.caretColumn], [0, 1])
    }

    func testPipesInCodeAndEscapesStayInCell() {
        XCTAssertEqual(MarkdownTable.cells("| `a|b` | c\\|d |"), ["`a|b`", "c\\|d"])
    }
}
