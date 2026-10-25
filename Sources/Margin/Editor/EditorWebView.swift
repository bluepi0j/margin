import AppKit
import MarginCore
import WebKit

/// Messages the editor page sends to native.
enum EditorEvent {
    case ready
    /// The first edit after the last content post (for "unsaved" UI).
    case edited(id: String)
    /// Debounced full content of an edited document.
    case content(id: String, markdown: String)
    case selection(EditorSelection)
    case openLink(String)
    case copy(String)
    /// Headings of the active document and its word count.
    case outline([OutlineItem], words: Int)
    /// The user asked to insert an image from a file (slash menu).
    case pickImage
}

struct OutlineItem: Identifiable, Equatable {
    let id: Int
    let level: Int
    let text: String
}

/// Formatting active at the caret; drives the toolbar's highlighted buttons.
struct EditorSelection: Equatable {
    var flags: Set<String> = []
    var heading = 0
    var sourceMode = false

    init() {}

    init(_ dict: [String: Any]) {
        for (k, v) in dict { if v as? Bool == true { flags.insert(k) } }
        heading = dict["heading"] as? Int ?? 0
        sourceMode = dict["source"] as? Bool ?? false
    }

    func has(_ key: String) -> Bool { flags.contains(key) }
}

/// The one WKWebView per window that hosts the editor page.
/// All documents (tabs) of the window live inside it; see WebEditor/src/main.ts.
final class EditorWebView: WKWebView {
    var onEvent: ((EditorEvent) -> Void)?
    /// Asked to handle file drops (images are inserted, documents opened).
    var onDropFiles: ((_ urls: [URL], _ point: CGPoint) -> Bool)?
    /// Asked to handle an image on the pasteboard; returns true if consumed.
    var onPasteImage: ((NSPasteboard) -> Bool)?
    /// Whether the caret is in a table, to offer row/column items on right-click.
    var caretInTable = false
    /// Runs an editor command chosen from the context menu.
    var onCommand: ((String) -> Void)?

    static let tableCommands: [(title: String, command: String)] = [
        ("Insert Row Above", "addRowBefore"), ("Insert Row Below", "addRowAfter"),
        ("Insert Column Left", "addColumnBefore"), ("Insert Column Right", "addColumnAfter"),
        ("", ""),
        ("Delete Row", "deleteRow"), ("Delete Column", "deleteColumn"), ("Delete Table", "deleteTable"),
    ]

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // Drop browser items that make no sense in an editor.
        for item in menu.items where ["Reload", "Back", "Forward", "Open Link", "Open Link in New Window",
                                       "Download Linked File", "Open Image in New Window", "Download Image"].contains(item.title) {
            menu.removeItem(item)
        }
        guard caretInTable else { return }
        var index = 0
        for (title, command) in Self.tableCommands {
            if title.isEmpty {
                menu.insertItem(.separator(), at: index)
            } else {
                let item = NSMenuItem(title: title, action: #selector(contextCommand(_:)), keyEquivalent: "")
                item.representedObject = command
                item.target = self
                menu.insertItem(item, at: index)
            }
            index += 1
        }
        menu.insertItem(.separator(), at: index)
    }

    @objc private func contextCommand(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? String { onCommand?(command) }
    }

    private(set) var isReady = false
    private var pending: [() -> Void] = []

    static func make() -> EditorWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: LocalFileSchemeHandler.scheme)
        config.suppressesIncrementalRendering = false
        config.preferences.isElementFullscreenEnabled = false
        config.preferences.isTextInteractionEnabled = true
        let controller = WKUserContentController()
        config.userContentController = controller

        let view = EditorWebView(frame: .zero, configuration: config)
        controller.add(WeakMessageHandler(view), name: "margin")
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = false
        view.allowsBackForwardNavigationGestures = false
        view.navigationDelegate = view
        view.uiDelegate = view
        #if DEBUG
        view.isInspectable = true
        #endif
        view.registerForDraggedTypes([.fileURL])
        view.loadPage()
        return view
    }

    private func loadPage() {
        guard let dir = Self.editorDirectory else {
            assertionFailure("Editor resources missing; run scripts/build-editor.sh")
            return
        }
        loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
    }

    /// Editor/ inside the app bundle, or the SwiftPM resource bundle when run with `swift run`.
    static var editorDirectory: URL? {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("Editor"),
           FileManager.default.fileExists(atPath: r.appendingPathComponent("index.html").path) {
            return r
        }
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Margin_Margin.bundle"),
            Bundle.main.bundleURL.appendingPathComponent("Margin_Margin.bundle"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("Margin_Margin.bundle"),
        ]
        for case let bundle? in candidates {
            let root = Bundle(url: bundle)?.resourceURL ?? bundle
            let dir = root.appendingPathComponent("Editor")
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.html").path) { return dir }
        }
        return nil
    }

    // MARK: Calling into the page

    /// Calls `window.margin.<function>(...)` once the page is ready.
    func call(_ function: String, _ args: KeyValuePairs<String, Any> = [:], completion: ((Any?) -> Void)? = nil) {
        let run = { [weak self] in
            guard let self else { return }
            let names = args.map(\.key).joined(separator: ", ")
            var dict: [String: Any] = [:]
            for (k, v) in args { dict[k] = v }
            self.callAsyncJavaScript("return window.margin.\(function)(\(names))", arguments: dict, in: nil, in: .page) { result in
                switch result {
                case .success(let value): completion?(value)
                case .failure(let error):
                    NSLog("Margin editor call \(function) failed: \(error)")
                    completion?(nil)
                }
            }
        }
        if isReady { run() } else { pending.append(run) }
    }

    /// Async variant for flows that must wait (save, close, quit).
    func callAsync(_ function: String, _ args: KeyValuePairs<String, Any> = [:]) async -> Any? {
        await withCheckedContinuation { cont in
            call(function, args) { cont.resume(returning: $0) }
        }
    }

    fileprivate func receive(_ body: Any) {
        guard let msg = body as? [String: Any], let type = msg["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            let queued = pending
            pending = []
            queued.forEach { $0() }
            onEvent?(.ready)
            #if DEBUG
            // Test hook: MARGIN_DEBUG_JS="<script>" runs in the page once it is ready
            // and logs the result, to check behaviour in the real WebKit.
            if let script = ProcessInfo.processInfo.environment["MARGIN_DEBUG_JS"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                        NSLog("MARGIN-DEBUG-JS %@", String(describing: result))
                    }
                }
            }
            #endif
        case "edited":
            if let id = msg["id"] as? String { onEvent?(.edited(id: id)) }
        case "content":
            if let id = msg["id"] as? String, let md = msg["markdown"] as? String { onEvent?(.content(id: id, markdown: md)) }
        case "selection":
            onEvent?(.selection(EditorSelection(msg["state"] as? [String: Any] ?? [:])))
        case "openLink":
            if let href = msg["href"] as? String { onEvent?(.openLink(href)) }
        case "copy":
            if let text = msg["text"] as? String { onEvent?(.copy(text)) }
        case "pickImage":
            onEvent?(.pickImage)
        case "outline":
            let raw = msg["items"] as? [[String: Any]] ?? []
            let items = raw.enumerated().map { i, item in
                OutlineItem(id: i, level: item["level"] as? Int ?? 1, text: item["text"] as? String ?? "")
            }
            onEvent?(.outline(items, words: msg["words"] as? Int ?? 0))
        default:
            break
        }
    }

    // MARK: Drag & drop and paste

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if fileURLs(sender.draggingPasteboard) != nil { return .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if fileURLs(sender.draggingPasteboard) != nil { return .copy }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let urls = fileURLs(sender.draggingPasteboard) {
            let p = convert(sender.draggingLocation, from: nil)
            let point = CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
            if onDropFiles?(urls, point) == true { return true }
        }
        return super.performDragOperation(sender)
    }

    private func fileURLs(_ pb: NSPasteboard) -> [URL]? {
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.isEmpty == false ? urls : nil
    }

    /// WKWebView implements `paste:` without declaring it, so call its
    /// implementation directly after giving pasted images a chance.
    @objc(paste:) func pasteFromMenu(_ sender: Any?) {
        if onPasteImage?(NSPasteboard.general) == true { return }
        let selector = #selector(pasteFromMenu(_:))
        guard let imp = class_getMethodImplementation(WKWebView.self, selector) else { return }
        typealias Paste = @convention(c) (AnyObject, Selector, Any?) -> Void
        unsafeBitCast(imp, to: Paste.self)(self, selector, sender)
    }
}

extension EditorWebView: WKUIDelegate {
    /// Links that ask for a new window (target=_blank) are opened by the app instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { onEvent?(.openLink(url.absoluteString)) }
        return nil
    }
}

extension EditorWebView: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Only the editor page itself may load; links are handled by the page.
        if action.navigationType == .other, action.request.url?.isFileURL == true {
            decisionHandler(.allow)
        } else {
            if let url = action.request.url, action.navigationType == .linkActivated {
                onEvent?(.openLink(url.absoluteString))
            }
            decisionHandler(.cancel)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The page crashed; reload it. The window re-sends its documents on .ready.
        isReady = false
        loadPage()
    }
}

/// Breaks the WKUserContentController -> handler retain cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: EditorWebView?
    init(_ target: EditorWebView) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message.body)
    }
}
