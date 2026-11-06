import XCTest
@testable import Margin

final class RailPreviewTests: XCTestCase {
    /// Same result as the old regex + split + join, without the regex.
    private func preview(_ s: String) -> String {
        NativeDocumentEditor.railPreview(s as NSString, in: NSRange(location: 0, length: (s as NSString).length))
    }

    func testPreviewDropsMarksAndCollapsesWhitespace() {
        let body = "\n- **Bold** item and `code`\n\n> quote | cell [link](x)\n  ==mark== 中文\n"
        let old = body.replacingOccurrences(of: #"[#>*_`~=|\[\]-]"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertEqual(preview(body), String(old.prefix(180)))
        let long = String(repeating: "word ", count: 100)
        XCTAssertEqual(preview(long),
                       String(long.split(separator: " ").joined(separator: " ").prefix(180)))
    }
}
