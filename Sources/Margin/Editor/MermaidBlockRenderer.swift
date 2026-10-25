import AppKit
import BeautifulMermaid
import MarkdownEngine

/// Draws ```mermaid blocks as diagrams in the native editor, with
/// BeautifulMermaid (the Swift twin of the beautiful-mermaid the web editor
/// uses), in the same two colors as the web page: its background and text.
final class MermaidBlockRenderer: CodeBlockRenderer, @unchecked Sendable {
    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 64
    }

    func renders(language: String) -> Bool { language == "mermaid" }

    func render(code: String, language: String, maxWidth: CGFloat) -> NSImage? {
        let dark = (NSApp.keyWindow?.effectiveAppearance ?? NSApp.effectiveAppearance)
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let key = "\(dark)|\(Int(maxWidth))|\(code)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        // Same colors as WebEditor/src/styles.css (--bg / --text).
        let theme = DiagramTheme(
            background: NSColor(white: dark ? 0.118 : 1, alpha: 1),
            foreground: dark ? NSColor(white: 0.902, alpha: 1)
                : NSColor(srgbRed: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255, alpha: 1),
            font: .systemFont(ofSize: 13),
            transparent: true
        )
        // A diagram mid-edit may not parse; then the block simply stays code.
        guard let diagram = try? MermaidRenderer.renderImage(source: code, theme: theme, scale: 2),
              diagram.size.width > 0 else { return nil }
        var size = diagram.size
        if size.width > maxWidth { size = NSSize(width: maxWidth, height: size.height * maxWidth / size.width) }
        // The engine draws rendered blocks into its flipped text view with a
        // plain draw(in:), as it does formulas; flip once here to stand upright.
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: 0, y: rect.height)
            context.scaleBy(x: 1, y: -1)
            diagram.draw(in: rect)
            return true
        }
        cache.setObject(image, forKey: key)
        return image
    }
}
