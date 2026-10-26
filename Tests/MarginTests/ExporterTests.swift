import XCTest
@testable import Margin

@MainActor
final class ExporterTests: XCTestCase {
    func testHTMLKeepsLocalImagesWhenExportedElsewhere() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("margin-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = Data([0x89, 0x50, 0x4E, 0x47])
        try data.write(to: folder.appendingPathComponent("a & b.png"))
        let page = Exporter.htmlPage(title: "Title <&", body: #"<img src="a%20&amp;%20b.png" alt="test"><img src="https://example.com/remote.png">"#,
                                     documentURL: folder.appendingPathComponent("note.md"))
        XCTAssertTrue(page.contains("src=\"data:image/png;base64,\(data.base64EncodedString())\""))
        XCTAssertTrue(page.contains("src=\"https://example.com/remote.png\""))
        XCTAssertTrue(page.contains("Title &lt;&amp;"))
    }

    func testFormulaFontsAreIncludedForOfflineHTML() async {
        let page = Exporter.htmlPage(title: "Math", body: "<p>Formula</p>")
        XCTAssertTrue(page.contains("data:font/woff2;base64,"))
        XCTAssertFalse(page.contains("cdn.jsdelivr.net"))
        XCTAssertFalse(page.contains("url(\"./fonts/"))
    }
}
