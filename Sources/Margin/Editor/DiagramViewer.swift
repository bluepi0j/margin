import AppKit
import BeautifulMermaid
import UniformTypeIdentifiers

/// A Mermaid diagram on its own, as large as you like. In the page a diagram
/// is at most as wide as the text column, so a big one shrinks until its
/// labels can't be read; here it gets a window, drawn as vectors (sharp at
/// any zoom), which you can pinch, scroll and drag, copy, and save as a PNG.
///
/// Both editors open it from a diagram's "Enlarge" button with the diagram's
/// source, and it is drawn with BeautifulMermaid, like the native editor's.
@MainActor
final class DiagramViewer: NSWindowController {
    static let shared = DiagramViewer()

    let canvas = DiagramCanvas()
    let scrollView = NSScrollView()
    private let zoomLabel = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private var needsDiagram: [NSControl] = []
    private var suggestedName = "Diagram"
    private var directory: URL?
    private var magnifyObserver: NSObjectProtocol?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Diagram"
        window.minSize = NSSize(width: 420, height: 300)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        build()
        magnifyObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.updateZoomLabel() } }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Shows the diagram `code` draws. `name` and `directory` are what the
    /// save panel starts with; `parent` is the window it was asked from.
    func show(code: String, name: String, directory: URL?, from parent: NSWindow?) {
        guard let window else { return }
        suggestedName = name
        self.directory = directory
        if !window.isVisible, !window.setFrameUsingName("MarginDiagram") {
            // First time: most of the screen the document is on.
            let screen = (parent?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            window.setFrame(screen.insetBy(dx: screen.width * 0.1, dy: screen.height * 0.08), display: false)
        }
        window.setFrameAutosaveName("MarginDiagram")
        let error = canvas.load(code)
        canvas.isHidden = error != nil
        message.isHidden = error == nil
        message.stringValue = error.map { "This diagram can’t be drawn.\n\($0)" } ?? ""
        needsDiagram.forEach { $0.isEnabled = error == nil }
        showWindow(nil)
        window.makeFirstResponder(canvas)
        window.layoutIfNeeded()
        fit()
    }

    // MARK: Layout

    private func build() {
        guard let content = window?.contentView else { return }
        scrollView.contentView = CenteringClipView()
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 16
        scrollView.backgroundColor = .textBackgroundColor

        message.alignment = .center
        message.textColor = .secondaryLabelColor
        message.isHidden = true

        let zoomOut = iconButton("minus.magnifyingglass", "Zoom Out (⌘−)", #selector(zoomOut(_:)))
        let zoomIn = iconButton("plus.magnifyingglass", "Zoom In (⌘+)", #selector(zoomIn(_:)))
        let fit = textButton("Fit", #selector(zoomToFit(_:)))
        fit.toolTip = "Show the whole diagram"
        let actual = textButton("100%", #selector(actualSize(_:)))
        actual.toolTip = "Actual Size (⌘0)"
        let copy = textButton("Copy", #selector(copyImage(_:)))
        copy.toolTip = "Copy the diagram as an image"
        let save = textButton("Save as PNG…", #selector(savePNG(_:)))
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        zoomLabel.textColor = .secondaryLabelColor
        zoomLabel.alignment = .center
        zoomLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        needsDiagram = [zoomOut, zoomIn, fit, actual, copy, save]

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        let bar = NSStackView(views: [zoomOut, zoomLabel, zoomIn, fit, actual, spacer, copy, save])
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        let line = NSBox()
        line.boxType = .separator

        for view in [scrollView, message, line, bar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: line.topAnchor),
            line.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 40),
            message.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -80),
        ])
    }

    private func textButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    private func iconButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let button = textButton("", action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.toolTip = label
        return button
    }

    // MARK: Zoom

    /// The whole diagram in view; a small one is enlarged, to twice its size at most.
    private func fit() {
        let size = canvas.frame.size
        let visible = scrollView.contentSize
        guard size.width > 0, size.height > 0, visible.width > 0, visible.height > 0 else { return }
        setMagnification(min(visible.width / size.width, visible.height / size.height, 2))
    }

    private func setMagnification(_ value: CGFloat) {
        let clip = scrollView.contentView.bounds
        scrollView.setMagnification(min(max(value, scrollView.minMagnification), scrollView.maxMagnification),
                                    centeredAt: NSPoint(x: clip.midX, y: clip.midY))
        updateZoomLabel()
    }

    private func updateZoomLabel() {
        zoomLabel.stringValue = "\(Int((scrollView.magnification * 100).rounded()))%"
    }

    // The View menu's Bigger Text, Smaller Text and Actual Size (⌘+, ⌘−, ⌘0)
    // reach these while this window is in front: here they size the diagram.
    @objc func zoomIn(_ sender: Any?) { setMagnification(scrollView.magnification * 1.25) }
    @objc func zoomOut(_ sender: Any?) { setMagnification(scrollView.magnification / 1.25) }
    @objc func actualSize(_ sender: Any?) { setMagnification(1) }
    @objc func zoomToFit(_ sender: Any?) { fit() }

    // File › Close Tab (⌘W) and Close Window.
    @objc func closeTab(_ sender: Any?) { window?.performClose(sender) }
    @objc func closeWindow(_ sender: Any?) { window?.performClose(sender) }

    // MARK: Getting the picture out

    @objc func copyImage(_ sender: Any?) {
        guard let png = canvas.pngData() else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
    }

    @objc func savePNG(_ sender: Any?) {
        guard let window, let png = canvas.pngData() else { return NSSound.beep() }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedName + ".png"
        panel.directoryURL = directory
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try png.write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }
}

/// The diagram, at its natural size (labels at 13 pt) with a margin around
/// it; the scroll view magnifies it. Drawn as vectors each time, so zooming
/// in stays sharp and costs no memory.
@MainActor
final class DiagramCanvas: NSView {
    static let margin: CGFloat = 24
    private var code = ""
    private var prepared: PreparedDiagram?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    /// Lays `code` out. Returns what went wrong when it can't be drawn.
    @discardableResult
    func load(_ code: String) -> String? {
        self.code = code
        var failure: String?
        do {
            prepared = try MermaidImageRenderer(theme: MermaidBlockRenderer.theme(dark: isDark)).prepare(from: code)
        } catch {
            prepared = nil
            failure = error.localizedDescription
        }
        let size = prepared?.bounds.size ?? .zero
        setFrameSize(NSSize(width: size.width + Self.margin * 2, height: size.height + Self.margin * 2))
        needsDisplay = true
        return prepared == nil ? failure ?? "It has nothing to draw." : nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if prepared != nil { load(code) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let prepared, let context = NSGraphicsContext.current?.cgContext else { return }
        context.translateBy(x: Self.margin - prepared.bounds.minX, y: Self.margin - prepared.bounds.minY)
        Self.render(prepared, in: context)
    }

    /// The renderer draws top-down into a context it takes for an unflipped
    /// one turned over by hand (as its own view does), and sets its labels
    /// accordingly: told the context is flipped, AppKit turns them over again.
    private static func render(_ diagram: PreparedDiagram, in context: CGContext) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        diagram.render(context, diagram.bounds)
        NSGraphicsContext.current = previous
    }

    /// The diagram as a PNG on the page's background color, at twice its
    /// size (less for a diagram so large that the picture would be enormous).
    func pngData() -> Data? {
        guard let prepared else { return nil }
        let theme = MermaidBlockRenderer.theme(dark: isDark, transparent: false)
        // The same layout, on an opaque background this time.
        guard let opaque = try? MermaidImageRenderer(theme: theme).prepare(from: code) else { return nil }
        let size = NSSize(width: prepared.bounds.width + Self.margin * 2, height: prepared.bounds.height + Self.margin * 2)
        let scale = min(2, 12_000 / max(size.width, size.height))
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(theme.background.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Top-down, like the view.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: Self.margin - opaque.bounds.minX, y: Self.margin - opaque.bounds.minY)
        Self.render(opaque, in: context)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    // MARK: Moving around

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    /// Dragging moves the diagram, for a mouse without a scroll surface.
    override func mouseDragged(with event: NSEvent) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        var bounds = clip.bounds
        bounds.origin.x -= event.deltaX / scroll.magnification
        bounds.origin.y -= event.deltaY / scroll.magnification
        clip.setBoundsOrigin(clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { window?.performClose(nil) } else { super.keyDown(with: event) }   // esc
    }
}

/// Keeps a document smaller than the view in the middle of it, not in a corner.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if document.frame.width < rect.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if document.frame.height < rect.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}
