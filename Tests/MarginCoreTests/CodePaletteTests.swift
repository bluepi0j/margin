import Foundation
import XCTest
@testable import MarginCore

/// The native editor's code colors come from `CodePalette`; the web editor's
/// from styles.css. They must say the same thing.
final class CodePaletteTests: XCTestCase {
    private let css: String = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(contentsOf: root.appendingPathComponent("WebEditor/src/styles.css"), encoding: .utf8)) ?? ""
    }()

    /// `--name: #rrggbb` values in order of appearance (light block first, then dark).
    private func values(_ name: String) -> [Int] {
        let re = try! NSRegularExpression(pattern: "--\(name):\\s*#([0-9a-fA-F]{6})\\s*;")
        return re.matches(in: css, range: NSRange(css.startIndex..., in: css)).compactMap {
            Range($0.range(at: 1), in: css).flatMap { Int(css[$0], radix: 16) }
        }
    }

    func testStylesheetFound() {
        XCTAssertFalse(css.isEmpty, "WebEditor/src/styles.css not found")
    }

    func testRoleColorsMatchStylesheet() {
        for role in CodePalette.Role.allCases {
            XCTAssertEqual(values("hl-\(role.rawValue)"), [CodePalette.light.roles[role]!, CodePalette.dark.roles[role]!],
                           "--hl-\(role.rawValue)")
        }
    }

    func testTextAndBackgroundMatchStylesheet() {
        XCTAssertEqual(values("hl-variable"), [CodePalette.light.text, CodePalette.dark.text])
        XCTAssertEqual(values("code-bg"), [CodePalette.light.background, CodePalette.dark.background])
    }

    func testEveryRoleHasScopes() {
        for role in CodePalette.Role.allCases { XCTAssertFalse(CodePalette.scopes[role, default: []].isEmpty, role.rawValue) }
    }
}
