import Foundation

/// New files that don't belong to a folder yet. They are real files in the
/// app's support folder, saved on every change like any other document, so
/// nothing is ever lost and no save dialog is needed to start writing.
public enum Drafts {
    public static var folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Margin/Drafts", isDirectory: true)
    }()

    public static func isDraft(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.deletingLastPathComponent().canonicalPath == folder.canonicalPath
    }

    /// Creates an empty draft file and returns its URL.
    public static func create() throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Draft-\(UUID().uuidString.prefix(8)).md")
        try TextFile.write("", to: url)
        return url
    }

    /// Relative image links in a draft point at files next to it (pasted
    /// images go to its `assets/`). When the draft is saved somewhere real,
    /// move those pasted images into `assets/` beside the new file and point
    /// other relative links at where they are, so none of them break.
    public static func relocateImages(in markdown: String, from source: URL, to destination: URL) -> String {
        let images = try! NSRegularExpression(pattern: #"!\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#)
        let ns = markdown as NSString
        var out = markdown
        for match in images.matches(in: markdown, range: NSRange(location: 0, length: ns.length)).reversed() {
            let link = ns.substring(with: match.range(at: 1))
            guard !link.contains(":"), !link.hasPrefix("/"), let path = link.removingPercentEncoding else { continue }
            let file = source.appendingPathComponent(path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            var target = file
            if file.isInside(source.appendingPathComponent("assets")) {
                let assets = destination.appendingPathComponent("assets")
                let moved = TextFile.availableURL(in: assets, base: file.deletingPathExtension().lastPathComponent, ext: file.pathExtension)
                do {
                    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: file, to: moved)
                    target = moved
                } catch {}
            }
            out = (out as NSString).replacingCharacters(in: match.range(at: 1), with: target.markdownLinkPath(from: destination))
        }
        return out
    }
}

public enum DocumentTitle {
    /// A file-name-safe title from the first line of a document:
    /// "# My Plan" -> "My Plan". nil when there is no usable text.
    public static func from(markdown: String, maxLength: Int = 60) -> String? {
        // "\r\n" is one Character, which `split` and `hasPrefix` below wouldn't see as "\n".
        var body = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        // Skip YAML front matter.
        if body.hasPrefix("---\n"), let end = body.range(of: "\n---", range: body.index(body.startIndex, offsetBy: 4)..<body.endIndex) {
            body = String(body[end.upperBound...])
        }
        guard let line = body.split(separator: "\n", omittingEmptySubsequences: true)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        var title = line
        // Strip block markers and inline formatting characters.
        title = title.replacingOccurrences(of: #"^([-*+] \[[ xX]\]|#{1,6}|>|[-*+]|\d+[.)])\s+"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        title = title.replacingOccurrences(of: #"[*_`~=$<>\\]"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"[/:|?"]"#, with: "-", options: .regularExpression)
        title = title.trimmingCharacters(in: CharacterSet.whitespaces.union(.init(charactersIn: ".-")))
        if title.count > maxLength { title = String(title.prefix(maxLength)).trimmingCharacters(in: .whitespaces) }
        return title.isEmpty ? nil : title
    }
}
