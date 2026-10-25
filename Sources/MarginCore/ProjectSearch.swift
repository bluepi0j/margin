import Foundation

/// Full-text search across the Markdown files of a project (⇧⌘F).
public enum ProjectSearch {
    public struct Match: Identifiable, Equatable, Sendable {
        public var id: String { "\(url.path)#\(line)" }
        public let url: URL
        /// 1-based line number.
        public let line: Int
        /// The line, trimmed and shortened around the match.
        public let snippet: String
        /// Range of the match inside `snippet`.
        public let range: Range<String.Index>
    }

    /// Case- and diacritic-insensitive search. Stops after `limit` matches.
    public static func search(_ query: String, in files: [URL], limit: Int = 500) -> [Match] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        var out: [Match] = []
        for url in files {
            guard let text = try? TextFile.read(url).text else { continue }
            guard text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { continue }
            var lineNo = 0
            text.enumerateLines { line, stop in
                lineNo += 1
                guard let r = line.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else { return }
                out.append(snippetMatch(url: url, line: lineNo, text: line, match: r))
                if out.count >= limit { stop = true }
            }
            if out.count >= limit { break }
        }
        return out
    }

    static func snippetMatch(url: URL, line: Int, text: String, match: Range<String.Index>) -> Match {
        // Keep ~40 characters of context before the match.
        let start = text.index(match.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(match.upperBound, offsetBy: 120, limitedBy: text.endIndex) ?? text.endIndex
        var snippet = String(text[start..<end])
        var prefix = ""
        if start > text.startIndex { prefix = "…" }
        let leading = snippet.prefix { $0 == " " || $0 == "\t" }.count
        snippet = prefix + String(snippet.dropFirst(prefix.isEmpty ? leading : 0))
        let offset = text.distance(from: start, to: match.lowerBound) + prefix.count - (prefix.isEmpty ? leading : 0)
        let lower = snippet.index(snippet.startIndex, offsetBy: max(0, offset))
        let upper = snippet.index(lower, offsetBy: text.distance(from: match.lowerBound, to: match.upperBound), limitedBy: snippet.endIndex) ?? snippet.endIndex
        return Match(url: url, line: line, snippet: snippet, range: lower..<upper)
    }
}
