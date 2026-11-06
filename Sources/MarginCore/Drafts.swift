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
        let code = codeRanges(in: ns)
        for match in images.matches(in: markdown, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard !isEscaped(match.range.location, in: ns),
                  !code.contains(where: { NSLocationInRange(match.range.location, $0) }) else { continue }
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

    /// Image-looking examples inside code are text, not assets. Keep offsets in
    /// UTF-16 so they can be compared directly with the image regex matches.
    private static func codeRanges(in text: NSString) -> [NSRange] {
        let fencePattern = try! NSRegularExpression(pattern: #"^[ \t]*(?:>[ \t]*)*(?:[-+*][ \t]+|[0-9]+[.)][ \t]+)?(`{3,}|~{3,})(.*)$"#)
        var ranges: [NSRange] = []
        var fence: (marker: String, start: Int)?
        var offset = 0
        while offset < text.length {
            var end = 0, contentsEnd = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contentsEnd,
                              for: NSRange(location: offset, length: 0))
            let line = text.substring(with: NSRange(location: offset, length: contentsEnd - offset)) as NSString
            if let match = fencePattern.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length)) {
                let marker = line.substring(with: match.range(at: 1))
                let suffix = line.substring(with: match.range(at: 2))
                if let open = fence {
                    if marker.first == open.marker.first, marker.count >= open.marker.count,
                       suffix.trimmingCharacters(in: .whitespaces).isEmpty {
                        ranges.append(NSRange(location: open.start, length: end - open.start))
                        fence = nil
                    }
                } else if marker.first != "`" || !suffix.contains("`") {
                    fence = (marker, offset)
                }
            }
            offset = end
        }
        if let fence { ranges.append(NSRange(location: fence.start, length: text.length - fence.start)) }

        // Match equal-length backtick runs, including multiline code spans.
        // Unmatched runs remain literal text and must not hide later images.
        let ticks = try! NSRegularExpression(pattern: "`+")
        let runs = ticks.matches(in: text as String, range: NSRange(location: 0, length: text.length))
            .map(\.range).filter { run in !ranges.contains { NSLocationInRange(run.location, $0) } }
        var i = 0
        while i < runs.count {
            let open = runs[i]
            if !isEscaped(open.location, in: text),
               let close = runs.indices.dropFirst(i + 1).first(where: { candidate in
                   runs[candidate].length == open.length &&
                   !ranges.contains { $0.location > open.location && $0.location < runs[candidate].location }
               }) {
                ranges.append(NSRange(location: open.location, length: NSMaxRange(runs[close]) - open.location))
                i = close + 1
            } else { i += 1 }
        }
        return ranges
    }

    private static func isEscaped(_ offset: Int, in text: NSString) -> Bool {
        var start = offset
        while start > 0, text.character(at: start - 1) == 0x5C { start -= 1 }
        return (offset - start) % 2 == 1
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
