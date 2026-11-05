import CoreGraphics

enum NativeFindBarLayout {
    static let railLeadingInset: CGFloat = 84
    static let plainLeadingInset: CGFloat = 12
    private static let minimumRailGutter: CGFloat = 64

    static func isRailVisible(
        showsRail: Bool,
        rawSourceMode: Bool,
        headingCount: Int,
        viewportWidth: CGFloat,
        readingWidth: CGFloat
    ) -> Bool {
        guard showsRail, !rawSourceMode, headingCount >= 3, viewportWidth > 0 else {
            return false
        }
        let contentWidth = min(max(0, readingWidth), viewportWidth)
        let gutter = (viewportWidth - contentWidth) / 2
        return gutter >= minimumRailGutter
    }

    static func leadingInset(
        showsRail: Bool,
        rawSourceMode: Bool,
        headingCount: Int,
        viewportWidth: CGFloat,
        readingWidth: CGFloat
    ) -> CGFloat {
        isRailVisible(
            showsRail: showsRail,
            rawSourceMode: rawSourceMode,
            headingCount: headingCount,
            viewportWidth: viewportWidth,
            readingWidth: readingWidth
        ) ? railLeadingInset : plainLeadingInset
    }
}
