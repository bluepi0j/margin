import XCTest
@testable import Margin

final class NativeFindBarLayoutTests: XCTestCase {
    func testFindBarAvoidsVisibleRail() {
        XCTAssertEqual(
            NativeFindBarLayout.leadingInset(
                showsRail: true,
                rawSourceMode: false,
                headingCount: 4,
                viewportWidth: 1_280,
                readingWidth: 820
            ),
            84
        )
    }

    func testFindBarUsesPlainInsetWhenRailIsHidden() {
        XCTAssertEqual(
            NativeFindBarLayout.leadingInset(
                showsRail: false,
                rawSourceMode: false,
                headingCount: 4,
                viewportWidth: 1_280,
                readingWidth: 820
            ),
            12
        )
    }

    func testFindBarUsesPlainInsetWhenRailHasNoRoom() {
        XCTAssertEqual(
            NativeFindBarLayout.leadingInset(
                showsRail: true,
                rawSourceMode: false,
                headingCount: 4,
                viewportWidth: 900,
                readingWidth: 820
            ),
            12
        )
    }

    func testFindBarIgnoresRailInSourceModeOrWithoutHeadings() {
        XCTAssertEqual(
            NativeFindBarLayout.leadingInset(
                showsRail: true,
                rawSourceMode: true,
                headingCount: 4,
                viewportWidth: 1_280,
                readingWidth: 820
            ),
            12
        )
        XCTAssertEqual(
            NativeFindBarLayout.leadingInset(
                showsRail: true,
                rawSourceMode: false,
                headingCount: 2,
                viewportWidth: 1_280,
                readingWidth: 820
            ),
            12
        )
    }
}
