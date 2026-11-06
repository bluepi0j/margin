import XCTest
@testable import MarginCore

final class MarkdownDiffTests: XCTestCase {
    private func contents(_ text: String) -> [String] {
        MarkdownDiff.blocks(in: text as NSString).map { (text as NSString).substring(with: $0.content) }
    }

    func testBlocksSplitAtBlankLinesHeadingsAndListItems() {
        let text = "---\ntitle: x\n\n---\n# Title\nPara one\nstill one\n\n- a\n  more a\n- b\n\n```js\nx\n\ny\n```\n\n$$\na\n\nb\n$$\n| a |\n| - |\n"
        XCTAssertEqual(contents(text), [
            "---\ntitle: x\n\n---", "# Title", "Para one\nstill one", "- a\n  more a", "- b",
            "```js\nx\n\ny\n```", "$$\na\n\nb\n$$", "| a |\n| - |",
        ])
    }

    func testSegmentsTileTheText() {
        let text = "\n\n# A\n\ntext\n\n\n- x\n- y\n"
        let blocks = MarkdownDiff.blocks(in: text as NSString)
        XCTAssertEqual(blocks.first?.segment.location, 0)
        for (a, b) in zip(blocks, blocks.dropFirst()) { XCTAssertEqual(NSMaxRange(a.segment), b.segment.location) }
        XCTAssertEqual(NSMaxRange(blocks.last!.segment), (text as NSString).length)
    }

    func testNoChanges() {
        XCTAssertEqual(MarkdownDiff.compute(base: "# A\n\nB\n", current: "# A\n\nB\n"), [])
        // Only blank lines differ: nothing worth showing.
        XCTAssertEqual(MarkdownDiff.compute(base: "# A\n\nB\n", current: "# A\n\n\nB\n"), [])
    }

    func testAddedRemovedAndRewrittenBlocks() {
        let base = "# Title\n\nKeep this.\n\nThe quick brown fox.\n\nGone paragraph.\n\nEnd.\n"
        let current = "# Title\n\nKeep this.\n\nThe quick red fox.\n\nEnd.\n\nNew last line.\n"
        let hunks = MarkdownDiff.compute(base: base, current: current)
        // The rewritten sentence, the removed paragraph, the added line.
        XCTAssertEqual(hunks.count, 3)
        let cur = current as NSString

        let rewrite = hunks[0]
        XCTAssertEqual(rewrite.removedText, "The quick brown fox.")
        XCTAssertEqual(rewrite.addedBlocks.map { cur.substring(with: $0) }, ["The quick red fox."])
        XCTAssertEqual(rewrite.addedWords.map { cur.substring(with: $0) }, ["red"])
        XCTAssertEqual(rewrite.removedWords.map { (rewrite.removedText as NSString).substring(with: $0) }, ["brown"])
        XCTAssertEqual(rewrite.ghost, .before(cur.range(of: "The quick").location))

        let removed = hunks[1]
        XCTAssertEqual(removed.removedText, "Gone paragraph.")
        XCTAssertEqual(removed.addedBlocks, [])
        XCTAssertEqual(removed.ghost, .before(cur.range(of: "End.").location))

        let added = hunks[2]
        XCTAssertEqual(added.removedText, "")
        XCTAssertNil(added.ghost)
        XCTAssertEqual(added.addedBlocks.map { cur.substring(with: $0) }, ["New last line."])
        XCTAssertEqual(added.addedWords, [])
    }

    func testRemovalAtTheEndIsShownAfterTheLastBlock() {
        let current = "A\n\nB\n"
        let hunks = MarkdownDiff.compute(base: "A\n\nB\n\nC\n", current: current)
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].removedText, "C")
        XCTAssertEqual(hunks[0].ghost, .after((current as NSString).range(of: "B")))
    }

    func testRewritesInARunAreSeparateChanges() {
        let base = "# Goals\n\nThe quick brown fox jumps over the lazy dog.\n\nThis paragraph will be removed by the agent.\n\n- Fast startup\n- Native look\n- Plain files\n"
        let current = "# Goals\n\nThe quick red fox leaps over the lazy dog.\n\nA brand new paragraph that the agent added here.\n\n- Fast startup\n- Native look and feel\n- Plain files\n"
        let hunks = MarkdownDiff.compute(base: base, current: current)
        XCTAssertEqual(hunks.map(\.removedText), ["The quick brown fox jumps over the lazy dog.",
                                                  "This paragraph will be removed by the agent.", "- Native look"])
        XCTAssertEqual(hunks.map(\.addedBlocks.count), [1, 1, 1])
    }

    func testUnrelatedRewriteHasNoWordMarks() {
        let hunks = MarkdownDiff.compute(base: "Alpha beta gamma delta.\n", current: "Something else entirely here.\n")
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].addedWords, [])
        XCTAssertEqual(hunks[0].removedWords, [])
    }

    func testChineseIsComparedByCharacter() {
        let current = "今天天气很好。\n"
        let hunks = MarkdownDiff.compute(base: "今天天气不错。\n", current: current)
        XCTAssertEqual(hunks[0].addedWords.map { (current as NSString).substring(with: $0) }, ["很好"])
    }

    /// Restoring every hunk, last first, gives back the committed blocks.
    func testRestoringEveryHunkGivesBackTheBase() {
        let cases: [(String, String)] = [
            ("# T\n\nA\n\nB\n\nC\n", "# T\n\nA changed\n\nC\n\nD\n"),
            ("A\n\nB", "A\n\nB\n\nC\n"),                // old file had no final newline
            ("A\n\nB\n\nC\n", "A\n"),                   // removed at the end
            ("A\n\nB\n", "Z\n\nA\n\nB\n"),              // added at the start
            ("Only\n", ""),
            ("", "New file\n\n- item\n"),
            ("- a\n- b\n- c\n", "- a\n- B!\n- c\n- d\n"),
            ("```\ncode\n\nmore\n```\n\nText\n", "Text\n"),
            ("A\n\nB\n\nC\n\nD\n", "B\n\nA\n\nD\n\nC\n"),  // moves
        ]
        for (base, current) in cases {
            var text = current
            for hunk in MarkdownDiff.compute(base: base, current: text).reversed() {
                let edit = MarkdownDiff.restore(hunk, base: base, current: text)
                text = (text as NSString).replacingCharacters(in: edit.range, with: edit.text)
            }
            XCTAssertEqual(MarkdownDiff.compute(base: base, current: text), [], "\(base.debugDescription) ← \(current.debugDescription) gave \(text.debugDescription)")
        }
    }

    /// Restoring puts back the committed text exactly, blank lines included.
    func testRestoringKeepsTheSeparation() {
        let cases: [(String, String)] = [
            ("- one\n- two\n- three\n", "- one\n- two changed\n- three\n"),
            ("- one\n- two\n- three\n", "- one\n- three\n"),
            ("- one\n- two\n", "- one\n- two\n- three\n"),
            ("A\n\nB\n\nC\n", "A\n\nC\n"),
            ("A\n\nB\n\nC\n", "A\n\nB changed\n\nC\n"),
            ("# T\n\nA\n\nB\n", "# T\n\nA\n"),
            ("# T\n\nA\n", "# T\n\nA\n\nAdded\n"),
            ("A\n- x\n", "A\n- y\n"),
            ("- one\r\n- two\r\n- three\r\n", "- one\r\n- three\r\n"),
        ]
        for (base, current) in cases {
            var text = current
            for hunk in MarkdownDiff.compute(base: base, current: text).reversed() {
                let edit = MarkdownDiff.restore(hunk, base: base, current: text)
                text = (text as NSString).replacingCharacters(in: edit.range, with: edit.text)
            }
            XCTAssertEqual(text, base, "\(base.debugDescription) ← \(current.debugDescription)")
        }
    }

    /// Restoring one hunk leaves the others alone.
    func testRestoringOneHunk() {
        let base = "A\n\nB\n\nC\n"
        let current = "A1\n\nB\n\nC1\n"
        let hunks = MarkdownDiff.compute(base: base, current: current)
        XCTAssertEqual(hunks.count, 2)
        let edit = MarkdownDiff.restore(hunks[1], base: base, current: current)
        XCTAssertEqual((current as NSString).replacingCharacters(in: edit.range, with: edit.text), "A1\n\nB\n\nC\n")
    }

    func testLargeDocumentDiffIsFast() {
        let section = (0..<20).map { "Paragraph \($0) with some words in it.\n\n" }.joined()
        let base = (0..<500).map { "## Section \($0)\n\n" + section }.joined()
        var current = base
        current = current.replacingOccurrences(of: "## Section 250\n", with: "## Section 250 renamed\n")
        current += "Appended.\n"
        let start = Date()
        let hunks = MarkdownDiff.compute(base: base, current: current)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        XCTAssertEqual(hunks.count, 2)
    }
}

final class GitBaselineTests: XCTestCase {
    private func git(_ dir: URL, _ args: [String]) throws {
        let p = Process()
        p.executableURL = try XCTUnwrap(GitBaseline.gitExecutable())
        p.arguments = ["-C", dir.path, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "git \(args)")
    }

    func testReadsTheCommittedText() throws {
        try XCTSkipIf(GitBaseline.gitExecutable() == nil, "git isn't installed")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("margin-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("sub/note one.md")
        try git(dir, ["init", "-q"])
        // No commits yet: everything is new.
        try "# First\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(GitBaseline.headText(for: file), .committed(""))
        try git(dir, ["add", "."])
        try git(dir, ["commit", "-q", "-m", "one"])
        try "# Changed\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(GitBaseline.repositoryRoot(for: file)?.resolvingSymlinksInPath().path, dir.resolvingSymlinksInPath().path)
        XCTAssertEqual(GitBaseline.headText(for: file), .committed("# First\n"))
        // Untracked file in the same repository.
        let other = dir.appendingPathComponent("new.md")
        try "x".write(to: other, atomically: true, encoding: .utf8)
        XCTAssertEqual(GitBaseline.headText(for: other), .committed(""))
    }

    func testOutsideARepository() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("margin-nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.md")
        try "a".write(to: file, atomically: true, encoding: .utf8)
        // The temporary folder isn't inside a working tree.
        XCTAssertNil(GitBaseline.repositoryRoot(for: file))
        XCTAssertEqual(GitBaseline.headText(for: file), .unavailable)
    }
}
