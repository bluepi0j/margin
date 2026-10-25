import Foundation

/// Text-level Markdown editing for the native (TextKit) editor: the toolbar
/// commands, the formatting state at the caret, the outline and word count.
/// Ranges are UTF-16 (NSString) ranges, as NSTextView uses.
public enum MarkdownEditing {
    /// Replace `range` with `text`, then select `selection`.
    public struct Edit: Equatable {
        public let range: NSRange
        public let text: String
        public let selection: NSRange

        public init(range: NSRange, text: String, selection: NSRange) {
            self.range = range
            self.text = text
            self.selection = selection
        }
    }

    // MARK: Inline marks

    public static let inlineMarkers: [String: String] = [
        "bold": "**", "italic": "*", "strike": "~~", "code": "`", "highlight": "==",
    ]

    /// Wraps the selection in `marker`, or removes it if already wrapped.
    /// With no selection, inserts a pair and puts the caret between.
    public static func toggleInline(_ text: String, _ sel: NSRange, marker: String) -> Edit {
        let ns = text as NSString
        let m = (marker as NSString).length
        // Already wrapped just outside the selection: unwrap.
        if sel.location >= m, NSMaxRange(sel) + m <= ns.length,
           ns.substring(with: NSRange(location: sel.location - m, length: m)) == marker,
           ns.substring(with: NSRange(location: NSMaxRange(sel), length: m)) == marker,
           !(marker == "*" && isBoldBoundary(ns, sel)) {
            let outer = NSRange(location: sel.location - m, length: sel.length + 2 * m)
            return Edit(range: outer, text: ns.substring(with: sel), selection: NSRange(location: outer.location, length: sel.length))
        }
        // Selection itself includes the markers: unwrap.
        let selected = ns.substring(with: sel)
        if sel.length >= 2 * m, selected.hasPrefix(marker), selected.hasSuffix(marker) {
            let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
            return Edit(range: sel, text: inner, selection: NSRange(location: sel.location, length: (inner as NSString).length))
        }
        let wrapped = marker + selected + marker
        return Edit(range: sel, text: wrapped, selection: NSRange(location: sel.location + m, length: sel.length))
    }

    private static func isBoldBoundary(_ ns: NSString, _ sel: NSRange) -> Bool {
        sel.location >= 2 && ns.substring(with: NSRange(location: sel.location - 2, length: 2)) == "**"
            && NSMaxRange(sel) + 2 <= ns.length && ns.substring(with: NSRange(location: NSMaxRange(sel), length: 2)) == "**"
    }

    public static func link(_ text: String, _ sel: NSRange, url: String = "") -> Edit {
        let ns = text as NSString
        let label = ns.substring(with: sel)
        let inserted = "[\(label)](\(url))"
        // Caret goes into the URL (or the label when there was none).
        let caret = label.isEmpty
            ? NSRange(location: sel.location + 1, length: 0)
            : NSRange(location: sel.location + (label as NSString).length + 3, length: 0)
        return Edit(range: sel, text: inserted, selection: caret)
    }

    // MARK: Line prefixes

    public enum LineKind: Equatable {
        case paragraph, heading(Int), bullet, ordered, task, quote
    }

    static let prefixPattern = try! NSRegularExpression(pattern: #"^(\s*)(#{1,6} |[-*+] \[[ xX]\] |[-*+] |\d+[.)] |> )?"#)

    /// The lines touched by the selection, as one range covering whole lines.
    public static func lineRange(_ text: String, _ sel: NSRange) -> NSRange {
        (text as NSString).lineRange(for: sel)
    }

    public static func kind(ofLine line: String) -> LineKind {
        let ns = line as NSString
        guard let m = prefixPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              m.range(at: 2).location != NSNotFound else { return .paragraph }
        let p = ns.substring(with: m.range(at: 2))
        if p.hasPrefix("#") { return .heading(p.filter { $0 == "#" }.count) }
        if p.contains("[") { return .task }
        if p.hasPrefix(">") { return .quote }
        if p.first?.isNumber == true { return .ordered }
        return .bullet
    }

    /// Sets (or toggles off) the block style of every selected line.
    public static func setLineKind(_ text: String, _ sel: NSRange, _ kind: LineKind) -> Edit {
        let ns = text as NSString
        let range = lineRange(text, sel)
        let block = ns.substring(with: range)
        var lines = block.components(separatedBy: "\n")
        // An empty last line (caret at the very end) is still one line to style.
        let trailing = lines.count > 1 && lines.last == "" ? lines.removeLast() : nil
        let allAlready = lines.allSatisfy { self.kind(ofLine: $0) == kind }
        var n = 0
        let out = lines.map { line -> String in
            let ln = line as NSString
            let m = prefixPattern.firstMatch(in: line, range: NSRange(location: 0, length: ln.length))!
            let indent = ln.substring(with: m.range(at: 1))
            let body = ln.substring(from: NSMaxRange(m.range))
            if allAlready || kind == .paragraph { return indent + body }
            n += 1
            switch kind {
            case .heading(let level): return String(repeating: "#", count: level) + " " + body
            case .bullet: return indent + "- " + body
            case .ordered: return indent + "\(n). " + body
            case .task: return indent + "- [ ] " + body
            case .quote: return indent + "> " + body
            case .paragraph: return indent + body
            }
        }
        var replacement = out.joined(separator: "\n")
        if trailing != nil { replacement += "\n" }
        // Keep the caret at the end of the (first) changed line's text.
        let delta = (replacement as NSString).length - range.length
        let newSel: NSRange = sel.length == 0
            ? NSRange(location: max(range.location, min(sel.location + (out.first.map { ($0 as NSString).length - ((lines.first ?? "") as NSString).length } ?? 0), range.location + (replacement as NSString).length)), length: 0)
            : NSRange(location: range.location, length: max(0, sel.length + delta))
        return Edit(range: range, text: replacement, selection: newSel)
    }

    // MARK: Blocks

    /// Inserts a block (code fence, table, formula, divider) on its own lines.
    public static func insertBlock(_ text: String, _ sel: NSRange, _ block: String, caretOffset: Int) -> Edit {
        let ns = text as NSString
        let prefix = ns.substring(to: sel.location)
        let after = NSMaxRange(sel) < ns.length ? ns.substring(with: NSRange(location: NSMaxRange(sel), length: 1)) : "\n"
        // Blocks get a blank line above them (unless at the top of the document).
        let lead = prefix.isEmpty || prefix.hasSuffix("\n\n") ? "" : (prefix.hasSuffix("\n") ? "\n" : "\n\n")
        let tail = after == "\n" ? "\n" : "\n\n"
        let insert = lead + block + tail
        return Edit(range: sel, text: insert, selection: NSRange(location: sel.location + (lead as NSString).length + caretOffset, length: 0))
    }

    public static func blockSnippet(_ command: String, selection: String) -> (String, Int)? {
        switch command {
        case "codeBlock": let b = "```\n\(selection)\n```"; return (b, 4)
        case "blockMath": let b = "$$\n\(selection)\n$$"; return (b, 3)
        case "table": return ("| Column | Column |\n| --- | --- |\n|  |  |", 2)
        case "horizontalRule": return ("---", 3)
        case "mermaid": return ("```mermaid\ngraph LR\n  A[Idea] --> B[Draft] --> C[Publish]\n```", 11)
        default: return nil
        }
    }

    // MARK: State at the caret

    public struct State: Equatable {
        public var flags: Set<String> = []
        public var heading = 0
        public init() {}
    }

    public static func state(_ text: String, caret: Int) -> State {
        var s = State()
        let ns = text as NSString
        let caret = min(max(0, caret), ns.length)
        let lineR = ns.lineRange(for: NSRange(location: caret, length: 0))
        let line = ns.substring(with: lineR).trimmingCharacters(in: .newlines)
        switch kind(ofLine: line) {
        case .heading(let l): s.heading = l
        case .bullet: s.flags.insert("bulletList")
        case .ordered: s.flags.insert("orderedList")
        case .task: s.flags.insert("taskList")
        case .quote: s.flags.insert("blockquote")
        case .paragraph: break
        }
        if isInsideFence(ns, at: caret) { s.flags.insert("codeBlock") }
        // Inline marks: an odd number of markers before the caret on this line.
        let col = caret - lineR.location
        let left = (line as NSString).substring(to: min(col, (line as NSString).length))
        func open(_ marker: String) -> Bool { left.components(separatedBy: marker).count % 2 == 0 }
        if open("**") { s.flags.insert("bold") }
        if open("~~") { s.flags.insert("strike") }
        if open("==") { s.flags.insert("highlight") }
        if open("`") { s.flags.insert("code") }
        if left.replacingOccurrences(of: "**", with: "").components(separatedBy: "*").count % 2 == 0 { s.flags.insert("italic") }
        if left.range(of: #"\[[^\]]*$"#, options: .regularExpression) != nil
            || left.range(of: #"\]\([^)]*$"#, options: .regularExpression) != nil { s.flags.insert("link") }
        return s
    }

    static func isInsideFence(_ ns: NSString, at caret: Int) -> Bool {
        let before = ns.substring(to: caret)
        var inside = false
        before.enumerateLines { line, _ in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inside.toggle() }
        }
        return inside
    }

    // MARK: Code fences

    /// A fenced code block's opening line.
    public struct CodeFence: Equatable, Sendable {
        /// The opening line, without its line break.
        public let openingLine: NSRange
        /// The language word after the fence (empty, at its insertion point, when there is none).
        public let languageRange: NSRange
        public let language: String
    }

    /// The fenced code block (``` or ~~~) that `caret` is in, counting its fence lines.
    public static func codeFence(containing caret: Int, in text: String) -> CodeFence? {
        let ns = text as NSString
        var open: CodeFence?
        var marker = ""
        var location = 0
        var result: CodeFence?
        text.enumerateLines { line, stop in
            let lineNS = line as NSString
            let lineRange = NSRange(location: location, length: lineNS.length)
            let indent = line.prefix { $0 == " " }.count
            let body = line.dropFirst(indent)
            if let current = open {
                // A closing fence: the same marker, nothing after it.
                if indent <= 3, body.hasPrefix(marker), body.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == marker.first }) {
                    if caret >= current.openingLine.location && caret <= NSMaxRange(lineRange) { result = current; stop = true }
                    open = nil
                }
            } else if indent <= 3, let fence = ["```", "~~~"].first(where: { body.hasPrefix($0) }) {
                let run = body.prefix { $0 == fence.first }.count
                marker = String(repeating: fence.first!, count: run)
                var start = location + indent + run
                while start < NSMaxRange(lineRange), ns.character(at: start) == 0x20 { start += 1 }
                var end = start
                while end < NSMaxRange(lineRange), let c = UnicodeScalar(ns.character(at: end)), !CharacterSet.whitespaces.contains(c) { end += 1 }
                let range = NSRange(location: start, length: end - start)
                open = CodeFence(openingLine: lineRange, languageRange: range, language: ns.substring(with: range))
            }
            location += lineNS.length + 1
        }
        if result == nil, let open, caret >= open.openingLine.location { return open }
        return result
    }

    /// Sets the language of `fence`: the edit to apply to the text.
    public static func setLanguage(_ language: String, of fence: CodeFence) -> Edit {
        Edit(range: fence.languageRange, text: language.trimmingCharacters(in: .whitespaces),
             selection: NSRange(location: fence.languageRange.location, length: 0))
    }

    // MARK: External changes

    /// Where a caret at `location` in `old` belongs in `new`: text added or
    /// removed before it shifts it, so it stays next to the same characters.
    public static func mapLocation(_ location: Int, from old: String, to new: String) -> Int {
        let a = old as NSString, b = new as NSString
        let limit = min(a.length, b.length)
        var prefix = 0
        while prefix < limit && a.character(at: prefix) == b.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix && a.character(at: a.length - 1 - suffix) == b.character(at: b.length - 1 - suffix) { suffix += 1 }
        if location <= prefix { return location }
        if location >= a.length - suffix { return location + (b.length - a.length) }
        return min(prefix + (b.length - prefix - suffix), b.length) // inside the changed part: end of it
    }

    // MARK: Outline and counts

    public struct Heading: Equatable {
        public let level: Int
        public let text: String
        /// UTF-16 offset of the heading line.
        public let location: Int
    }

    public static func headings(_ text: String) -> [Heading] {
        var out: [Heading] = []
        var inFence = false
        var location = 0
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            if !inFence, case .heading(let level) = kind(ofLine: line) {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: #"[*_`~=]"#, with: "", options: .regularExpression)
                out.append(Heading(level: level, text: title, location: location))
            }
            location += (line as NSString).length + 1
        }
        return out
    }

    /// Words in Latin text plus one per CJK character, the usual convention.
    public static func wordCount(_ text: String) -> Int {
        var cjk = 0
        var latin = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let isCJK = (0x3040...0x30FF).contains(v) || (0x3400...0x4DBF).contains(v)
                || (0x4E00...0x9FFF).contains(v) || (0xAC00...0xD7AF).contains(v)
            if isCJK {
                cjk += 1
                inWord = false
            } else if CharacterSet.alphanumerics.contains(scalar) || scalar == "'" || scalar == "’" {
                if !inWord { latin += 1; inWord = true }
            } else {
                inWord = false
            }
        }
        return cjk + latin
    }
}
