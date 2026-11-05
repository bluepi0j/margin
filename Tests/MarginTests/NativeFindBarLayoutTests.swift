import XCTest
@testable import Margin

final class NativeFindBarLayoutTests: XCTestCase {
    func testFindBarAvoidsVisibleRail() {
        XCTAssertEqual(NativeFindBarLayout.leadingInset(railVisible: true), 84)
    }

    func testFindBarUsesPlainInsetWhenRailIsHidden() {
        XCTAssertEqual(NativeFindBarLayout.leadingInset(railVisible: false), 12)
    }
}
