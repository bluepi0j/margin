import XCTest
@testable import MarginCore

final class OpenRouterTests: XCTestCase {
    let projA = URL(fileURLWithPath: "/tmp/margin-tests/A")
    let projB = URL(fileURLWithPath: "/tmp/margin-tests/B")
    let nested = URL(fileURLWithPath: "/tmp/margin-tests/A/sub")

    func file(_ p: String) -> URL { URL(fileURLWithPath: "/tmp/margin-tests/" + p) }

    func testFolderOpensNewWindowWhenNoneOpen() {
        XCTAssertEqual(OpenRouter.route(projA, isDirectory: true, windows: [], keyWindow: nil),
                       .newWindow(folder: projA, file: nil))
    }

    func testFolderAlreadyOpenFocusesItsWindow() {
        let windows = [OpenRouter.WindowInfo(id: 1, folder: projB, openFiles: []),
                       OpenRouter.WindowInfo(id: 2, folder: projA, openFiles: [])]
        XCTAssertEqual(OpenRouter.route(projA, isDirectory: true, windows: windows, keyWindow: 1), .focusWindow(2))
    }

    func testFolderReusesEmptyKeyWindow() {
        let windows = [OpenRouter.WindowInfo(id: 1, folder: nil, openFiles: [])]
        XCTAssertEqual(OpenRouter.route(projA, isDirectory: true, windows: windows, keyWindow: 1),
                       .adoptFolder(window: 1, folder: projA))
    }

    func testSecondFolderGetsItsOwnWindow() {
        let windows = [OpenRouter.WindowInfo(id: 1, folder: projA, openFiles: [])]
        XCTAssertEqual(OpenRouter.route(projB, isDirectory: true, windows: windows, keyWindow: 1),
                       .newWindow(folder: projB, file: nil))
    }

    func testFolderDoesNotAdoptWindowWithLooseTabs() {
        let windows = [OpenRouter.WindowInfo(id: 1, folder: nil, openFiles: [file("x.md")])]
        XCTAssertEqual(OpenRouter.route(projA, isDirectory: true, windows: windows, keyWindow: 1),
                       .newWindow(folder: projA, file: nil))
    }

    func testFolderDoesNotAdoptWindowWithUntitledTab() {
        let windows = [OpenRouter.WindowInfo(id: 1, folder: nil, openFiles: [], tabCount: 1)]
        XCTAssertEqual(OpenRouter.route(projA, isDirectory: true, windows: windows, keyWindow: 1),
                       .newWindow(folder: projA, file: nil))
    }

    func testFileInsideProjectGoesToProjectWindowEvenIfNotKey() {
        let windows = [OpenRouter.WindowInfo(id: 1, folder: projB, openFiles: []),
                       OpenRouter.WindowInfo(id: 2, folder: projA, openFiles: [])]
        XCTAssertEqual(OpenRouter.route(file("A/notes.md"), isDirectory: false, windows: windows, keyWindow: 1),
                       .openTab(window: 2, file: file("A/notes.md")))
    }

    func testDeepestProjectWins() {
        let windows = [OpenRouter.WindowInfo(id: 1, folder: projA, openFiles: []),
                       OpenRouter.WindowInfo(id: 2, folder: nested, openFiles: [])]
        XCTAssertEqual(OpenRouter.route(file("A/sub/x.md"), isDirectory: false, windows: windows, keyWindow: 1),
                       .openTab(window: 2, file: file("A/sub/x.md")))
    }

    func testOutsideFileOpensAsTabInKeyWindow() {
        let windows = [OpenRouter.WindowInfo(id: 1, folder: projA, openFiles: []),
                       OpenRouter.WindowInfo(id: 2, folder: projB, openFiles: [])]
        XCTAssertEqual(OpenRouter.route(file("elsewhere.md"), isDirectory: false, windows: windows, keyWindow: 2),
                       .openTab(window: 2, file: file("elsewhere.md")))
    }

    func testOutsideFileWithoutWindowsMakesOne() {
        XCTAssertEqual(OpenRouter.route(file("x.md"), isDirectory: false, windows: [], keyWindow: nil),
                       .newWindow(folder: nil, file: file("x.md")))
    }

    func testAlreadyOpenFileIsFocused() {
        let windows = [OpenRouter.WindowInfo(id: 1, folder: projB, openFiles: []),
                       OpenRouter.WindowInfo(id: 2, folder: nil, openFiles: [file("x.md")])]
        XCTAssertEqual(OpenRouter.route(file("x.md"), isDirectory: false, windows: windows, keyWindow: 1),
                       .focusTab(window: 2, file: file("x.md")))
    }

    func testSiblingFolderWithSharedPrefixIsNotInside() {
        let windows = [OpenRouter.WindowInfo(id: 1, folder: projA, openFiles: []),
                       OpenRouter.WindowInfo(id: 2, folder: nil, openFiles: [])]
        // "/A-other" must not count as inside "/A"
        XCTAssertEqual(OpenRouter.route(file("A-other/x.md"), isDirectory: false, windows: windows, keyWindow: 2),
                       .openTab(window: 2, file: file("A-other/x.md")))
    }
}
