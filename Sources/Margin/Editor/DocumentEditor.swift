import AppKit
import SwiftUI

/// What a window needs from its editor. Two implementations, picked in
/// Settings › Editor:
///   - `WebDocumentEditor`: TipTap in a WKWebView (WYSIWYG, tables, Mermaid…)
///   - `NativeDocumentEditor`: a TextKit 2 live-Markdown view
/// Each window owns one editor instance that holds all of its tabs (`id` = tab id).
@MainActor
protocol DocumentEditor: AnyObject {
    var onEvent: ((EditorEvent) -> Void)? { get set }
    /// Called with pasted images; returns the Markdown image path to insert, or nil.
    var savePastedImage: ((NSPasteboard) -> String?)? { get set }
    /// The SwiftUI view to place in the window.
    var view: AnyView { get }
    /// The view that should become first responder.
    var focusView: NSView? { get }

    func open(id: String, markdown: String, documentURL: URL?, activate: Bool)
    func activate(id: String)
    func close(id: String)
    /// The file changed on disk; keep the caret and scroll position.
    func reload(id: String, markdown: String)
    /// The document moved (affects relative image paths).
    func moved(id: String, documentURL: URL?)
    func command(_ name: String, args: [String: Any])
    /// Every not-yet-reported edit, as id → Markdown.
    func flush() async -> [String: String]
    func setSourceMode(_ on: Bool)
    func find(_ mode: String)
    func applySettings()
    func focus()
    func goToHeading(_ index: Int)
    /// Shows the first occurrence of `text` (project search results).
    func reveal(_ text: String)
}

/// The TipTap editor page (WebEditor/) in a WKWebView.
@MainActor
final class WebDocumentEditor: DocumentEditor {
    let webView = EditorWebView.make()
    var onEvent: ((EditorEvent) -> Void)? {
        get { webView.onEvent }
        set { webView.onEvent = newValue }
    }
    var savePastedImage: ((NSPasteboard) -> String?)?
    /// Dropped files (images are inserted where they land).
    var onDropFiles: ((_ urls: [URL], _ point: CGPoint) -> Bool)? {
        get { webView.onDropFiles }
        set { webView.onDropFiles = newValue }
    }

    init() {
        webView.onPasteImage = { [weak self] pb in
            guard let self, let src = self.savePastedImage?(pb) else { return false }
            self.command("image", args: ["src": src])
            return true
        }
        webView.onCommand = { [weak self] name in self?.command(name, args: [:]) }
    }

    var view: AnyView { AnyView(WebViewHost(webView: webView)) }
    var focusView: NSView? { webView }

    func open(id: String, markdown: String, documentURL: URL?, activate: Bool) {
        webView.call("open", ["id": id, "markdown": markdown, "base": LocalFileSchemeHandler.baseURL(for: documentURL), "activate": activate])
    }
    func activate(id: String) { webView.call("activate", ["id": id]) }
    func close(id: String) { webView.call("close", ["id": id]) }
    func reload(id: String, markdown: String) { webView.call("reload", ["id": id, "markdown": markdown]) }
    func moved(id: String, documentURL: URL?) {
        webView.call("rename", ["oldId": id, "newId": id, "base": LocalFileSchemeHandler.baseURL(for: documentURL)])
    }
    func command(_ name: String, args: [String: Any]) { webView.call("command", ["name": name, "args": args]) }
    func flush() async -> [String: String] { await webView.callAsync("flush") as? [String: String] ?? [:] }
    func setSourceMode(_ on: Bool) { webView.call("setSourceMode", ["on": on]) }
    func find(_ mode: String) { webView.call("find", ["mode": mode]) }
    func applySettings() { webView.call("settings", ["s": Preferences.shared.editorSettings]) }
    func focus() { webView.call("focus") }
    func goToHeading(_ index: Int) { webView.call("goToHeading", ["index": index]) }
    func reveal(_ text: String) { webView.call("reveal", ["query": text]) }

    /// Keeps the right-click table items in sync with the caret.
    func selectionChanged(_ state: EditorSelection) { webView.caretInTable = state.has("table") }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: EditorWebView
    func makeNSView(context: Context) -> EditorWebView { webView }
    func updateNSView(_ nsView: EditorWebView, context: Context) {}
}
