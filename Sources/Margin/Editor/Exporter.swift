import AppKit
import UniformTypeIdentifiers
import WebKit

/// Export to HTML / PDF and printing. Renders the Markdown in its own
/// offscreen editor page, so the output is the same whichever editor
/// (web or native) the window uses, with formulas and diagrams drawn.
@MainActor
final class Exporter {
    enum Kind { case html, pdf, print }

    private let webView = EditorWebView.make()
    private let window: NSWindow
    private var ready = false
    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init() {
        // A page needs a window to lay out and print; this one is never shown.
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 820, height: 1100),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        webView.onEvent = { [weak self] event in
            guard case .ready = event, let self else { return }
            self.ready = true
            self.waiters.forEach { $0.resume() }
            self.waiters = []
        }
    }

    private func waitUntilReady() async {
        if ready { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Renders `markdown` (of the file at `url`) and returns the page's HTML body.
    private func render(_ markdown: String, documentURL: URL?) async -> (title: String, body: String)? {
        await waitUntilReady()
        webView.call("settings", ["s": ["fontSize": 15, "width": 720, "accent": Preferences.controlAccentHex, "rail": false]])
        // The page keeps an already-registered document as-is, so drop the
        // previous export first — otherwise exporting tab B after tab A
        // renders A again.
        webView.call("close", ["id": "export"])
        webView.call("open", ["id": "export", "markdown": markdown, "base": LocalFileSchemeHandler.baseURL(for: documentURL), "activate": true])
        // The page waits for diagrams, fonts and images before returning.
        guard let result = await webView.callAsync("exportHTML") as? [String: Any],
              let body = result["body"] as? String else { return nil }
        return (result["title"] as? String ?? "", body)
    }

    func run(_ kind: Kind, markdown: String, documentURL: URL?, suggestedName: String, in parent: NSWindow) async {
        guard !isRunning, parent.attachedSheet == nil else { return NSSound.beep() }
        isRunning = true
        defer { isRunning = false }
        // Ask where to save first; the page renders while the user decides.
        var destination: URL?
        if kind != .print {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [kind == .html ? .html : .pdf]
            panel.nameFieldStringValue = suggestedName + (kind == .html ? ".html" : ".pdf")
            panel.directoryURL = documentURL?.deletingLastPathComponent()
            async let rendered = render(markdown, documentURL: documentURL)
            let response = await panel.beginSheetModal(for: parent)
            let page = await rendered
            guard response == .OK, let url = panel.url else { return }
            guard let page else { return NSSound.beep() }
            destination = url
            if kind == .html {
                do {
                    try Self.htmlPage(title: page.title.isEmpty ? suggestedName : page.title, body: page.body, documentURL: documentURL)
                        .write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    await NSAlert(error: error).beginSheetModal(for: parent)
                }
                return
            }
        } else if await render(markdown, documentURL: documentURL) == nil {
            return NSSound.beep()
        }

        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.topMargin = 54
        info.bottomMargin = 54
        info.leftMargin = 54
        info.rightMargin = 54
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        if let destination {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = destination
        }
        let op = webView.printOperation(with: info)
        op.view?.frame = webView.bounds
        op.showsPrintPanel = kind == .print
        op.showsProgressPanel = false
        op.jobTitle = suggestedName
        op.runModal(for: parent, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// A self-contained HTML page: the editor's styles, inlined.
    static func htmlPage(title: String, body: String, documentURL: URL? = nil) -> String {
        let resources = EditorWebView.editorDirectory
        let cssURL = resources?.appendingPathComponent("editor.css")
        var css = cssURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        // Keep formulas usable offline without making readers contact a CDN.
        let fonts = try! NSRegularExpression(pattern: #"url\("\./(fonts/[^"\)]+)"\)"#)
        for match in fonts.matches(in: css, range: NSRange(css.startIndex..., in: css)).reversed() {
            let path = (css as NSString).substring(with: match.range(at: 1))
            guard let url = resources?.appendingPathComponent(path), let data = try? Data(contentsOf: url) else { continue }
            css = (css as NSString).replacingCharacters(in: match.range, with: "url(\"data:font/woff2;base64,\(data.base64EncodedString())\")")
        }
        var body = body
        let images = try! NSRegularExpression(pattern: #"<img\b[^>]*\bsrc="([^"]+)""#)
        for match in images.matches(in: body, range: NSRange(body.startIndex..., in: body)).reversed() {
            let src = (body as NSString).substring(with: match.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: src, relativeTo: documentURL?.deletingLastPathComponent()).map(\.absoluteURL),
                  url.isFileURL, let data = try? Data(contentsOf: url) else { continue }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            body = (body as NSString).replacingCharacters(in: match.range(at: 1), with: "data:\(mime);base64,\(data.base64EncodedString())")
        }
        let escapedTitle = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapedTitle)</title>
        <style>
        \(css)
        body { padding: 0 }
        #page { padding: 48px 32px 96px }
        </style>
        </head>
        <body>
        <div id="page">
        \(body)
        </div>
        </body>
        </html>
        """
    }
}
