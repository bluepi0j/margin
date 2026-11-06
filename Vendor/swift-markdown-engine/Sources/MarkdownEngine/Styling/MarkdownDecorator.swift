//
//  MarkdownDecorator.swift
//  MarkdownEngine
//
//  [Margin patch] A hook for the host to lay its own marks over the styled
//  text (Margin shows the changes since the last git commit with it), and to
//  draw inside a paragraph's layout fragment.
//

import AppKit

/// Adds host attributes after the engine has styled some paragraphs. Styling
/// resets every attribute of the paragraphs it touches, so this runs after
/// each restyle, over the same paragraphs (display coordinates).
@MainActor
public protocol MarkdownDecorator: AnyObject, Sendable {
    func decorate(_ storage: NSMutableAttributedString, paragraphs: [NSRange])
}

/// What a host draws in a paragraph's layout fragment: put an instance on the
/// paragraph's first character under `.fragmentDrawing`.
@MainActor
public protocol MarkdownFragmentDrawing: AnyObject {
    /// Area painted, in the coordinates of `draw` with a zero origin.
    func surface(in geometry: MarkdownFragmentGeometry) -> CGRect
    /// Draws behind the text. The current NSGraphicsContext is flipped.
    func draw(in geometry: MarkdownFragmentGeometry)
}

/// Where a paragraph's fragment sits, for `MarkdownFragmentDrawing`.
public struct MarkdownFragmentGeometry {
    /// The whole fragment (paragraph spacing included), at its draw origin.
    public let frame: CGRect
    /// Top of the first line and bottom of the last one.
    public let textTop: CGFloat
    public let textBottom: CGFloat
    /// The text container's left edge and width (the column the text wraps in).
    public let columnLeft: CGFloat
    public let columnWidth: CGFloat
    /// Line-fragment padding: how far the text starts inside the column.
    public let padding: CGFloat
}

public extension NSAttributedString.Key {
    /// [Margin patch] A `MarkdownFragmentDrawing` drawn by the fragment of the
    /// paragraph this attribute starts.
    static let fragmentDrawing = NSAttributedString.Key("MarkdownFragmentDrawing")
}

public extension NSTextView {
    /// [Margin patch] Styles the paragraphs around `ranges` again (and runs
    /// the decorator over them), e.g. after the decorator's marks changed.
    /// Marks can change paragraph heights, so the document height is measured
    /// again too (from what TextKit has laid out: keep `ranges` near the
    /// viewport, or the whole document gets laid out).
    func restyleMarkdownParagraphs(_ ranges: [NSRange]) {
        guard let coordinator = delegate as? NativeTextViewCoordinator else { return }
        let text = string as NSString
        let paragraphs = ranges.compactMap { range -> NSRange? in
            guard range.location <= text.length else { return nil }
            return text.paragraphRange(for: NSRange(location: range.location, length: min(range.length, text.length - range.location)))
        }
        guard !paragraphs.isEmpty else { return }
        coordinator.restyleParagraphs(paragraphs, in: self)
        if let textView = self as? NativeTextView, let scrollView = enclosingScrollView {
            textView.recalcOverscroll(for: scrollView, debugTag: "decorations")
            (scrollView as? ClampedScrollView)?.clampToInsets()
        }
    }
}
