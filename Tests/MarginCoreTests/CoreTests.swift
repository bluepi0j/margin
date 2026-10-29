import XCTest
@testable import MarginCore

final class TabTitleTests: XCTestCase {
    func testUniqueNamesHaveNoHint() {
        let t = TabTitles.titles(for: [URL(fileURLWithPath: "/a/x.md"), URL(fileURLWithPath: "/a/y.md")], untitledNames: [nil, nil])
        XCTAssertEqual(t.map(\.title), ["x.md", "y.md"])
        XCTAssertEqual(t.map(\.hint), [nil, nil])
    }

    func testDuplicateNamesGetParentHint() {
        let t = TabTitles.titles(for: [URL(fileURLWithPath: "/p/work/todo.md"), URL(fileURLWithPath: "/p/home/todo.md")], untitledNames: [nil, nil])
        XCTAssertEqual(t.map(\.hint), ["work", "home"])
    }

    func testDuplicateNamesWithSameParentNameWalkUp() {
        let t = TabTitles.titles(for: [URL(fileURLWithPath: "/a/notes/x.md"), URL(fileURLWithPath: "/b/notes/x.md")], untitledNames: [nil, nil])
        XCTAssertEqual(t.map(\.hint), ["a/notes", "b/notes"])
    }

    func testHintNeverIncludesTheRoot() {
        let t = TabTitles.titles(for: [URL(fileURLWithPath: "/a/x.md"), URL(fileURLWithPath: "/b/a/x.md")], untitledNames: [nil, nil])
        XCTAssertEqual(t.map(\.hint), ["a", "b/a"])
    }

    func testUntitled() {
        let t = TabTitles.titles(for: [nil], untitledNames: ["Untitled 2"])
        XCTAssertEqual(t[0].title, "Untitled 2")
    }
}

final class FuzzyMatchTests: XCTestCase {
    func testSubsequence() {
        XCTAssertNotNil(FuzzyMatch.score("rdm", path: "README.md"))
        XCTAssertNil(FuzzyMatch.score("xyz", path: "README.md"))
    }

    func testFileNameBeatsFolder() {
        let ranked = FuzzyMatch.rank("todo", paths: ["todo-archive/notes.md", "work/todo.md"])
        XCTAssertEqual(ranked.first, "work/todo.md")
    }

    func testEmptyQueryMatchesAll() {
        XCTAssertEqual(FuzzyMatch.rank("", paths: ["b.md", "a.md"]).count, 2)
    }
}

final class PathTests: XCTestCase {
    func testRelativePath() {
        let doc = URL(fileURLWithPath: "/p/notes")
        XCTAssertEqual(URL(fileURLWithPath: "/p/notes/img/a.png").relativePath(from: doc), "img/a.png")
        XCTAssertEqual(URL(fileURLWithPath: "/p/assets/a.png").relativePath(from: doc), "../assets/a.png")
    }

    func testCanonicalPathMatchesFSEventsForm() {
        XCTAssertEqual(URL(fileURLWithPath: "/private/tmp/x/gone.md").canonicalPath, "/tmp/x/gone.md")
        XCTAssertEqual(URL(fileURLWithPath: "/tmp/x").canonicalPath, "/tmp/x")
        XCTAssertEqual(URL(fileURLWithPath: "/Users/a/b.md").canonicalPath, "/Users/a/b.md")
    }

    func testIsInside() {
        XCTAssertTrue(URL(fileURLWithPath: "/p/a/b.md").isInside(URL(fileURLWithPath: "/p/a")))
        XCTAssertFalse(URL(fileURLWithPath: "/p/ab/b.md").isInside(URL(fileURLWithPath: "/p/a")))
    }
}

final class FileTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("margin-core-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func touch(_ path: String, _ text: String = "") throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testTreeShowsMarkdownAndSkipsNoise() throws {
        try touch("b.md"); try touch("A.md"); try touch("image.png")
        try touch("docs/guide.md"); try touch("empty/readme.txt.bak")
        try touch("node_modules/pkg/README.md"); try touch(".git/HEAD.md")
        let tree = FileTreeLoader.load(root: dir)
        XCTAssertEqual(tree.map(\.name), ["docs", "A.md", "b.md"])
        XCTAssertEqual(tree[0].children?.map(\.name), ["guide.md"])
    }

    func testTreeShowAll() throws {
        try touch("a.md"); try touch("image.png")
        XCTAssertEqual(FileTreeLoader.load(root: dir, showAllFiles: true).map(\.name), ["a.md", "image.png"])
    }

    func testTreeDoesNotFollowDirectorySymlinks() throws {
        try touch("docs/a.md")
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("docs/loop"), withDestinationURL: dir)
        XCTAssertEqual(FileTreeLoader.load(root: dir).flatMap(\.allFiles).map(\.lastPathComponent), ["a.md"])
    }

    func testTreeBudgetCountsEmptyDirectories() throws {
        try touch("nested/deeper/hidden.md")
        XCTAssertTrue(FileTreeLoader.load(root: dir, maxEntries: 1).isEmpty)
    }

    func testNaturalSort() throws {
        try touch("note 10.md"); try touch("note 2.md")
        XCTAssertEqual(FileTreeLoader.load(root: dir).map(\.name), ["note 2.md", "note 10.md"])
    }

    func testReadWriteRoundTrip() throws {
        let url = dir.appendingPathComponent("x.md")
        try TextFile.write("# 你好\n", to: url)
        XCTAssertEqual(try TextFile.read(url).text, "# 你好\n")
    }

    func testReadStripsBOM() throws {
        let url = dir.appendingPathComponent("bom.md")
        try Data([0xEF, 0xBB, 0xBF] + Array("hi".utf8)).write(to: url)
        XCTAssertEqual(try TextFile.read(url).text, "hi")
    }

    func testLatin1IsNotMistakenForUTF16() throws {
        let url = dir.appendingPathComponent("latin1.md")
        try Data([0x63, 0x61, 0x66, 0xE9]).write(to: url)
        XCTAssertEqual(try TextFile.read(url).text, "café")
    }

    func testUTF16WithBOMStillReads() throws {
        let url = dir.appendingPathComponent("utf16.md")
        try XCTUnwrap("# 你好\n".data(using: .utf16)).write(to: url)
        XCTAssertEqual(try TextFile.read(url).text, "# 你好\n")
    }

    func testWritingThroughSymlinkKeepsTheLinkAndUpdatesItsTarget() throws {
        let target = dir.appendingPathComponent("target.md")
        let link = dir.appendingPathComponent("link.md")
        try TextFile.write("old", to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try TextFile.write("new", to: link)
        XCTAssertEqual(try TextFile.read(target).text, "new")
        XCTAssertTrue(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    func testBinaryIsRejected() throws {
        let url = dir.appendingPathComponent("bin.md")
        try Data([0x00, 0x01, 0x02]).write(to: url)
        XCTAssertThrowsError(try TextFile.read(url))
    }

    func testAvailableURL() throws {
        try touch("Untitled.md")
        XCTAssertEqual(TextFile.availableURL(in: dir, base: "Untitled", ext: "md").lastPathComponent, "Untitled 2.md")
    }

    func testSessionPrune() {
        let s = SessionState(windows: [
            .init(folder: "/gone", files: ["/keep.md", "/gone.md"], activeFile: "/gone.md", sidebarVisible: true, frame: nil),
            .init(folder: nil, files: ["/gone.md"], activeFile: nil, sidebarVisible: true, frame: nil),
        ])
        let p = s.pruned { $0 == "/keep.md" }
        XCTAssertEqual(p.windows.count, 1)
        XCTAssertNil(p.windows[0].folder)
        XCTAssertEqual(p.windows[0].activeFile, "/keep.md")
        XCTAssertEqual(SessionState.decode(p.encoded()), p)
    }
}

final class DocumentTitleTests: XCTestCase {
    func testTitles() {
        XCTAssertEqual(DocumentTitle.from(markdown: "# My Plan\n\nbody"), "My Plan")
        XCTAssertEqual(DocumentTitle.from(markdown: "\n\n**Bold** start: a/b"), "Bold start- a-b")
        XCTAssertEqual(DocumentTitle.from(markdown: "- [ ] task one"), "task one")
        XCTAssertEqual(DocumentTitle.from(markdown: "---\ntitle: x\n---\n\n## Real"), "Real")
        XCTAssertEqual(DocumentTitle.from(markdown: "[link text](http://a.b) more"), "link text more")
        XCTAssertNil(DocumentTitle.from(markdown: "  \n\n"))
        XCTAssertEqual(DocumentTitle.from(markdown: "# 中文标题"), "中文标题")
    }

    func testTitleFromCRLFDocument() {
        XCTAssertEqual(DocumentTitle.from(markdown: "# My Plan\r\n\r\nbody"), "My Plan")
        XCTAssertEqual(DocumentTitle.from(markdown: "---\r\ntitle: x\r\n---\r\n\r\n## Real"), "Real")
    }

    func testSavingADraftTakesItsImagesAlong() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("margin-draft-\(UUID().uuidString)")
        let drafts = base.appendingPathComponent("Drafts")
        let docs = base.appendingPathComponent("out/docs")
        try FileManager.default.createDirectory(at: drafts.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data([1]).write(to: drafts.appendingPathComponent("assets/shot 1.png"))
        try Data([2]).write(to: base.appendingPathComponent("pic.png"))
        let markdown = "![a](assets/shot%201.png) ![b](../pic.png) ![c](https://x/y.png) ![d](assets/missing.png)"
        let out = Drafts.relocateImages(in: markdown, from: drafts, to: docs)
        XCTAssertEqual(out, "![a](assets/shot%201.png) ![b](../../pic.png) ![c](https://x/y.png) ![d](assets/missing.png)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: docs.appendingPathComponent("assets/shot 1.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: drafts.appendingPathComponent("assets/shot 1.png").path))
    }

    func testDraftDetection() {
        XCTAssertTrue(Drafts.isDraft(Drafts.folder.appendingPathComponent("Draft-1.md")))
        XCTAssertFalse(Drafts.isDraft(URL(fileURLWithPath: "/tmp/x.md")))
    }
}

final class ProjectSearchTests: XCTestCase {
    func testFindsMatchesWithContext() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("margin-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.md"), b = dir.appendingPathComponent("b.md")
        try "# Plan\n\n    Ship the Café release\nnothing".write(to: a, atomically: true, encoding: .utf8)
        try "no match here".write(to: b, atomically: true, encoding: .utf8)
        let m = ProjectSearch.search("cafe", in: [a, b])
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].line, 3)
        XCTAssertEqual(String(m[0].snippet[m[0].range]), "Café")
        XCTAssertTrue(m[0].snippet.hasPrefix("Ship"))
        XCTAssertTrue(ProjectSearch.search("  ", in: [a]).isEmpty)
    }
}
