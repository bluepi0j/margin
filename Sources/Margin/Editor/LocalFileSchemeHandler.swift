import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves local files (images next to a document) to the editor page as
/// `margin-file:///absolute/path`. The page itself loads from the app bundle.
final class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "margin-file"

    /// Tasks WebKit cancelled; answering them would raise an exception.
    private var stopped = Set<ObjectIdentifier>()

    /// `margin-file:///dir/` for a document's folder; relative image paths resolve against it.
    static func baseURL(for document: URL?) -> String {
        guard let dir = document?.deletingLastPathComponent() else { return "" }
        let s = URL(fileURLWithPath: dir.path, isDirectory: true).absoluteString
        return scheme + s.dropFirst("file".count)
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let path = url.path(percentEncoded: false)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let mime = UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                let response = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
                DispatchQueue.main.async {
                    guard self.stopped.remove(ObjectIdentifier(task)) == nil else { return }
                    task.didReceive(response)
                    task.didReceive(data)
                    task.didFinish()
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.stopped.remove(ObjectIdentifier(task)) == nil else { return }
                    task.didFailWithError(error)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }
}
