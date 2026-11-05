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
    /// copy those pasted images into `assets/` beside the new file and point
    /// other relative links at where they are, so none of them break. Keep the
    /// originals: saving can fail, and other drafts can reference the same asset.
    public static func relocateImages(
        in markdown: String,
        from source: URL,
        to destination: URL,
        copyAllLocalImages: Bool = false
    ) -> String {
        // Capture either a pointy-bracket destination (`<name with spaces>`)
        // or a bare destination, including escaped parentheses. Titles may use
        // any of Markdown's three delimiters.
        let images = try! NSRegularExpression(pattern: #"!\[(?:\\.|[^\]\\])*\]\((<(?:\\.|[^>\\\r\n])*>|(?:\\.|[^)\s\\])+)(?:\s+(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\((?:\\.|[^)\\])*\)))?\)"#)
        let ns = markdown as NSString
        var out = markdown
        var targets: [URL: URL] = [:]
        guard source.resolvingSymlinksInPath().standardizedFileURL != destination.resolvingSymlinksInPath().standardizedFileURL else { return markdown }
        for match in images.matches(in: markdown, range: NSRange(location: 0, length: ns.length)).reversed() {
            let rawLink = ns.substring(with: match.range(at: 1))
            let link = rawLink.hasPrefix("<") && rawLink.hasSuffix(">")
                ? String(rawLink.dropFirst().dropLast())
                : rawLink
            let unescaped = link.replacingOccurrences(
                of: #"\\(.)"#,
                with: "$1",
                options: .regularExpression
            )
            guard !unescaped.contains(":"),
                  !unescaped.hasPrefix("/"),
                  let path = unescaped.removingPercentEncoding else { continue }
            let file = source.appendingPathComponent(path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            var target = targets[file] ?? file
            let shouldCopy = file.isInside(source.appendingPathComponent("assets"))
                || (copyAllLocalImages && file.isInside(source))
            if targets[file] == nil, shouldCopy {
                let relative = file.relativePath(from: source)
                let preferred = destination.appendingPathComponent(relative)
                let copied = FileManager.default.fileExists(atPath: preferred.path)
                    ? TextFile.availableURL(in: preferred.deletingLastPathComponent(),
                                            base: preferred.deletingPathExtension().lastPathComponent,
                                            ext: preferred.pathExtension)
                    : preferred
                do {
                    try FileManager.default.createDirectory(at: copied.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: file, to: copied)
                    target = copied
                } catch {}
            }
            targets[file] = target
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
