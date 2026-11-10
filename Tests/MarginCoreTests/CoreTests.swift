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

    func testFilesOutsideTheFolderShowWhereTheyAre() {
        let home = URL(fileURLWithPath: "/Users/me")
        let t = TabTitles.titles(for: [URL(fileURLWithPath: "/Users/me/project/a.md"),
                                       URL(fileURLWithPath: "/Users/me/Downloads/b.md"),
                                       URL(fileURLWithPath: "/Users/me/c.md"),
                                       URL(fileURLWithPath: "/tmp/d.md"),
                                       nil],
                                 untitledNames: [nil, nil, nil, nil, "Untitled"],
                                 folder: URL(fileURLWithPath: "/Users/me/project"), home: home)
        XCTAssertEqual(t.map(\.title), ["a.md", "b.md", "c.md", "d.md", "Untitled"])
        XCTAssertEqual(t.map(\.hint), [nil, "~/Downloads", "~", "/tmp", nil])
        // A visitor with the name of a file inside: the inside one gets its
        // folder hint, the visitor its location.
        let clash = TabTitles.titles(for: [URL(fileURLWithPath: "/Users/me/project/notes/todo.md"),
                                           URL(fileURLWithPath: "/Users/me/Desktop/todo.md")],
                                     untitledNames: [nil, nil], folder: URL(fileURLWithPath: "/Users/me/project"), home: home)
        XCTAssertEqual(clash.map(\.hint), ["notes", "~/Desktop"])
        // No folder open: no location hints.
        XCTAssertEqual(TabTitles.titles(for: [URL(fileURLWithPath: "/tmp/d.md")], untitledNames: [nil]).map(\.hint), [nil])
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

    func testSavingAFileThatIsNotUTF8KeepsItsOtherBytes() throws {
        // "中文" in GBK: not UTF-8, so it reads as Latin-1 (and shows as "ÖÐÎÄ").
        let gbk: [UInt8] = [0xD6, 0xD0, 0xCE, 0xC4, 0x0A]
        let url = dir.appendingPathComponent("gbk.txt")
        try Data(gbk).write(to: url)
        let file = try TextFile.read(url)
        XCTAssertEqual(file.encoding, .isoLatin1)
        try TextFile.write(file.text + "ok\n", to: url, encoding: file.encoding)
        XCTAssertEqual(try Data(contentsOf: url), Data(gbk + Array("ok\n".utf8)))
        // Text that encoding can't hold is refused, and the file left alone.
        XCTAssertThrowsError(try TextFile.write(file.text + "中", to: url, encoding: file.encoding))
        XCTAssertEqual(try Data(contentsOf: url), Data(gbk + Array("ok\n".utf8)))
    }

    func testSavingUTF16KeepsItsByteOrder() throws {
        for (encoding, bom) in [(String.Encoding.utf16BigEndian, [0xFE, 0xFF] as [UInt8]), (.utf16LittleEndian, [0xFF, 0xFE])] {
            let url = dir.appendingPathComponent("utf16-\(bom[0]).md")
            try (Data(bom) + XCTUnwrap("# 你好\n".data(using: encoding))).write(to: url)
            let file = try TextFile.read(url)
            XCTAssertEqual(file.text, "# 你好\n")
            XCTAssertEqual(file.encoding, encoding)
            try TextFile.write("# 你好!\n", to: url, encoding: file.encoding)
            XCTAssertEqual(try Data(contentsOf: url), try Data(bom) + XCTUnwrap("# 你好!\n".data(using: encoding)))
        }
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: drafts.appendingPathComponent("assets/shot 1.png").path))
    }

    func testDraftImagesSurviveFailedSaveAndRepeatedReferences() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("margin-draft-\(UUID().uuidString)")
        let drafts = base.appendingPathComponent("Drafts")
        let docs = base.appendingPathComponent("Docs")
        let fm = FileManager.default
        for directory in [drafts, docs] {
            try fm.createDirectory(at: directory.appendingPathComponent("assets"), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: base) }
        let original = drafts.appendingPathComponent("assets/shot.png")
        try Data([1]).write(to: original)
        try Data([2]).write(to: docs.appendingPathComponent("assets/shot.png"))
        let markdown = "![a](assets/shot.png) ![b](assets/shot.png)"
        let out = Drafts.relocateImages(in: markdown, from: drafts, to: docs)
        XCTAssertEqual(out, "![a](assets/shot%202.png) ![b](assets/shot%202.png)")
        XCTAssertEqual(try Data(contentsOf: docs.appendingPathComponent("assets/shot 2.png")), Data([1]))
        XCTAssertEqual(try Data(contentsOf: docs.appendingPathComponent("assets/shot.png")), Data([2]))
        // A destination directory makes writing the Markdown fail. The draft
        // and any other draft sharing this image must remain usable.
        XCTAssertThrowsError(try TextFile.write(out, to: docs))
        XCTAssertEqual(try Data(contentsOf: original), Data([1]))
        XCTAssertEqual(Drafts.relocateImages(in: markdown, from: drafts, to: drafts), markdown)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: drafts.appendingPathComponent("assets").path), ["shot.png"])
    }

    func testSavingARegularFileCopiesAllLocalImages() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("margin-save-as-\(UUID().uuidString)")
        let source = base.appendingPathComponent("Source")
        let destination = base.appendingPathComponent("Destination")
        let fm = FileManager.default
        try fm.createDirectory(at: source.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("images/deep"), withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        try Data([1]).write(to: source.appendingPathComponent("assets/shot.png"))
        try Data([3]).write(to: source.appendingPathComponent("assets/shot (1).png"))
        try Data([4]).write(to: source.appendingPathComponent("assets/paren(2).png"))
        try Data([2]).write(to: source.appendingPathComponent("images/deep/map.svg"))
        let markdown = "![shot](assets/shot.png) ![a \\] b](<assets/shot (1).png>) ![paren](assets/paren\\(2\\).png \"a \\\"quoted\\\" title\") ![map](images/deep/map.svg) ![remote](https://x/y.png)"

        let out = Drafts.relocateImages(
            in: markdown,
            from: source,
            to: destination,
            copyAllLocalImages: true
        )

        XCTAssertEqual(out, "![shot](assets/shot.png) ![a \\] b](assets/shot%20%281%29.png) ![paren](assets/paren%282%29.png \"a \\\"quoted\\\" title\") ![map](images/deep/map.svg) ![remote](https://x/y.png)")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("assets/shot.png")), Data([1]))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("assets/shot (1).png")), Data([3]))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("assets/paren(2).png")), Data([4]))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("images/deep/map.svg")), Data([2]))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("assets/shot.png")), Data([1]))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("images/deep/map.svg")), Data([2]))
    }

    func testDraftDetection() {
        XCTAssertTrue(Drafts.isDraft(Drafts.folder.appendingPathComponent("Draft-1.md")))
        XCTAssertFalse(Drafts.isDraft(URL(fileURLWithPath: "/tmp/x.md")))
    }

    func testImageRelocationPreservesCodeExamplesAndEscapedImages() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("source")
        let destination = base.appendingPathComponent("destination")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: base) }
        for folder in [source, destination] {
            try fm.createDirectory(at: folder.appendingPathComponent("assets"), withIntermediateDirectories: true)
            try Data([1]).write(to: folder.appendingPathComponent("assets/shot.png"))
        }
        let image = "![example](assets/shot.png)"
        let examples = [
            "```markdown\n\(image)\n```",
            "~~~~\n\(image)\n~~~\n\(image)\n~~~~",
            "> ```markdown\n> \(image)\n> ```",
            "- ```markdown\n  \(image)\n  ```",
            "`\(image)`", "``a ` \(image)``", "`first\n\(image)`",
            "\\\(image)",
        ].joined(separator: "\n\n")
        for copyAll in [false, true] {
            let out = Drafts.relocateImages(in: "中文 👋\n\n\(examples)\n\n\(image)",
                                           from: source, to: destination, copyAllLocalImages: copyAll)
            XCTAssertTrue(out.hasPrefix("中文 👋\n\n\(examples)\n\n"))
            XCTAssertFalse(out.hasSuffix(image))
        }
        // An unfinished fence protects the rest; a lone backtick does not.
        XCTAssertEqual(Drafts.relocateImages(in: "```\n\(image)", from: source, to: destination), "```\n\(image)")
        XCTAssertNotEqual(Drafts.relocateImages(in: "a ` \(image)", from: source, to: destination), "a ` \(image)")
        let markedAlt = "![`example`](assets/shot.png)"
        XCTAssertNotEqual(Drafts.relocateImages(in: markedAlt, from: source, to: destination), markedAlt)
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
