import CoreGraphics

enum NativeFindBarLayout {
    static let railLeadingInset: CGFloat = 84
    static let plainLeadingInset: CGFloat = 12

    static func leadingInset(railVisible: Bool) -> CGFloat {
        railVisible ? railLeadingInset : plainLeadingInset
    }
}
