import AppKit
import MarginCore
import MarkdownEngine

/// Changes since the last git commit in the native editor: added and
/// rewritten blocks get a green tint (changed words stronger), removed blocks
/// are drawn as red "ghosts" in space opened above the block that follows
/// them. Only attributes and drawing — the text itself is never touched, so
/// saving, undo and find see the real document.
///
/// The engine calls `decorate` after it styles paragraphs; the marks for
/// those paragraphs are put back on each time.
@MainActor
final class NativeDiffDecorator: MarkdownDecorator {
    weak var textView: NSTextView?
    /// The committed text being compared against; nil: not showing changes.
    private(set) var base: String?
    private(set) var hunks: [MarkdownDiff.Hunk] = []
    /// The text `hunks` were computed for, and the length of the text the
    /// marks now refer to (they follow edits until the next recompute).
    private var text: NSString = ""
    private var textLength = 0

    // Marks for the current text, by paragraph.
    private var tinted: [NSRange] = []          // added/rewritten blocks
    private var words: [NSRange] = []           // changed words
    private var ghosts: [Ghost] = []
    /// Ranges whose marks changed but haven't been restyled yet: off screen,
    /// they wait until they scroll near (restyling far text makes TextKit
    /// lay out the whole document — seconds for a big note).
    private var pending: [NSRange] = []

    var fontName = ""
    var fontSize: CGFloat = 16

    struct Ghost {
        /// The block the removed text is drawn above (or below, at the end).
        var anchor: Int
        var below: Bool
        let text: String
        let removedWords: [NSRange]
    }

    var isActive: Bool { base != nil }

    // MARK: Diffing

    /// Sets the committed text and diffs `current` against it. Returns the
    /// ranges whose marks changed (to restyle).
    @discardableResult
    func setBase(_ base: String?, current: String) -> [NSRange] {
        let before = marks()
        self.base = base
        recompute(current)
        return changed(from: before)
    }

    /// Diffs the current text again. Returns the ranges whose marks changed.
    @discardableResult
    func refresh(_ current: String) -> [NSRange] {
        if textLength != (current as NSString).length { textChanged(to: current) }
        let before = marks()
        recompute(current)
        return changed(from: before)
    }

    /// Every mark, keyed by what it looks like, with the range it sits on.
    private func marks() -> [String: NSRange] {
        var out: [String: NSRange] = [:]
        for r in tinted { out["t\(r.location):\(r.length)"] = r }
        for r in words { out["w\(r.location):\(r.length)"] = r }
        for g in ghosts { out["g\(g.anchor):\(g.below):\(g.removedWords.count):\(g.text.hashValue)"] = NSRange(location: g.anchor, length: 0) }
        return out
    }

    /// Ranges of marks that were added or dropped since `before`.
    private func changed(from before: [String: NSRange]) -> [NSRange] {
        let after = marks()
        var ranges: [NSRange] = []
        for (key, range) in before where after[key] == nil { ranges.append(range) }
        for (key, range) in after where before[key] == nil { ranges.append(range) }
        return ranges
    }

    private func recompute(_ current: String) {
        text = current as NSString
        textLength = text.length
        guard let base else {
            hunks = []; tinted = []; words = []; ghosts = []
            ghostCache.removeAll()
            return
        }
        hunks = MarkdownDiff.compute(base: base, current: current)
        tinted = hunks.flatMap(\.addedBlocks)
        words = hunks.flatMap(\.addedWords)
        ghosts = hunks.compactMap { hunk in
            switch hunk.ghost {
            case .before(let at): Ghost(anchor: at, below: false, text: hunk.removedText, removedWords: hunk.removedWords)
            case .after(let block): Ghost(anchor: block.location, below: true, text: hunk.removedText, removedWords: hunk.removedWords)
            case nil: nil
            }
        }
    }

    /// The text storage reported an edit (`range` is the new text's, after
    /// a change of `delta` in length): move the marks along with it until the
    /// next recompute. Cheap, unlike `textChanged`, which has to find the edit.
    func storageEdited(_ range: NSRange, delta: Int, newLength: Int) {
        guard base != nil else { return }
        guard textLength + delta == newLength else { return }
        let oldEnd = NSMaxRange(range) - delta
        func start(_ location: Int) -> Int { location <= range.location ? location : location >= oldEnd ? location + delta : range.location }
        func end(_ location: Int) -> Int { location <= range.location ? location : location >= oldEnd ? location + delta : NSMaxRange(range) }
        func map(_ r: NSRange) -> NSRange {
            let s = start(r.location), e = max(s, end(NSMaxRange(r)))
            return NSRange(location: s, length: e - s)
        }
        tinted = tinted.map(map)
        words = words.map(map).filter { $0.length > 0 }
        for i in ghosts.indices { ghosts[i].anchor = start(ghosts[i].anchor) }
        pending = pending.map(map)
        textLength = newLength
    }

    /// The text changed some other way: find the edit (a scan of the whole
    /// text) and move the marks along with it.
    func textChanged(to current: String) {
        guard base != nil else { return }
        let new = current as NSString
        // The marks followed edits `text` didn't see: no common ground to
        // find this edit from. Leave them; the next recompute redoes them.
        guard text.length == textLength else {
            text = new
            textLength = new.length
            return
        }
        let old = text
        let oldLength = old.length, newLength = new.length
        var prefix = 0
        let limit = min(oldLength, newLength)
        while prefix < limit, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, old.character(at: oldLength - 1 - suffix) == new.character(at: newLength - 1 - suffix) { suffix += 1 }
        let delta = newLength - oldLength
        let editEnd = oldLength - suffix
        func map(_ location: Int) -> Int { location >= editEnd ? location + delta : min(location, prefix + max(0, newLength - suffix - prefix)) }
        func map(_ range: NSRange) -> NSRange {
            let start = map(range.location), end = max(start, map(NSMaxRange(range)))
            return NSRange(location: start, length: end - start)
        }
        tinted = tinted.map(map)
        words = words.map(map).filter { $0.length > 0 }
        for i in ghosts.indices { ghosts[i].anchor = map(ghosts[i].anchor) }
        pending = pending.map(map)
        text = new
        textLength = newLength
    }

    /// Remembers ranges to restyle once they come near the screen.
    func addPending(_ ranges: [NSRange]) { pending += ranges }

    /// Forgets pending ranges: the whole document is being styled anyway.
    func clearPending() { pending = [] }

    /// Pending ranges that touch `window`, removed from the list.
    func takePending(in window: NSRange) -> [NSRange] {
        var taken: [NSRange] = [], kept: [NSRange] = []
        for range in pending {
            let touches = NSIntersectionRange(range, window).length > 0
                || (range.location >= window.location && range.location <= NSMaxRange(window))
            if touches { taken.append(range) } else { kept.append(range) }
        }
        pending = kept
        return taken
    }

    /// Where each change starts in the current text, for the restore buttons.
    var hunkAnchors: [Int] {
        hunks.indices.map { anchor(of: $0) }
    }

    func anchor(of index: Int) -> Int {
        let hunk = hunks[index]
        if let first = hunk.addedBlocks.first { return first.location }
        switch hunk.ghost {
        case .before(let at): return at
        case .after(let block): return block.location
        case nil: return hunk.new.location
        }
    }

    // MARK: MarkdownDecorator

    func decorate(_ storage: NSMutableAttributedString, paragraphs: [NSRange]) {
        guard base != nil, storage.length > 0 else { return }
        // The engine restyles the edited paragraph before the text binding
        // reports the edit: catch up here so the marks land on the new text.
        if storage.length != textLength, let first = paragraphs.map(\.location).min(),
           let last = paragraphs.map({ NSMaxRange($0) }).max() {
            // The edit is in the paragraphs being restyled (the engine styles
            // the typed paragraph before the storage notification comes):
            // take those as the edited range instead of scanning the text.
            storageEdited(NSRange(location: first, length: last - first),
                          delta: storage.length - textLength, newLength: storage.length)
        }
        let ns = storage.string as NSString
        let width = columnWidth
        for paragraph in paragraphs {
            for range in tinted {
                let overlap = NSIntersectionRange(range, paragraph)
                guard overlap.length > 0 else { continue }
                // Every line of the block is its own fragment: mark each.
                var location = overlap.location
                while location < NSMaxRange(overlap) {
                    let line = ns.paragraphRange(for: NSRange(location: location, length: 0))
                    drawing(for: line.location, in: storage).tint = true
                    location = max(NSMaxRange(line), location + 1)
                }
            }
            for range in words {
                let clipped = NSIntersectionRange(range, paragraph)
                guard clipped.length > 0, NSMaxRange(clipped) <= storage.length else { continue }
                storage.addAttribute(.backgroundColor, value: Self.addedWordColor, range: clipped)
            }
            for ghost in ghosts {
                let at = min(ghost.anchor, storage.length - 1)
                let line = ghost.below ? lastLine(from: at, in: ns) : ns.paragraphRange(for: NSRange(location: at, length: 0))
                guard NSIntersectionRange(line, paragraph).length > 0 else { continue }
                let rendered = render(ghost, width: width)
                let drawing = drawing(for: line.location, in: storage)
                if ghost.below { drawing.ghostBelow = rendered } else { drawing.ghostAbove = rendered }
                let space = rendered.height + Self.ghostPadding * 2 + Self.ghostGap
                let style = (storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle ?? .default)
                    .mutableCopy() as! NSMutableParagraphStyle
                // Paragraph ranges can overlap within one pass, and a line the
                // engine didn't restyle keeps its old style: replace the space
                // this added before rather than adding to it.
                let key: NSAttributedString.Key = ghost.below ? .diffSpaceBelow : .diffSpaceAbove
                let previous = storage.attribute(key, at: line.location, effectiveRange: nil) as? CGFloat ?? 0
                if ghost.below { style.paragraphSpacing += space - previous } else { style.paragraphSpacingBefore += space - previous }
                storage.addAttributes([.paragraphStyle: style, key: space], range: line)
            }
        }
    }

    /// The drawing on a paragraph's first character, created on first use.
    private func drawing(for location: Int, in storage: NSMutableAttributedString) -> DiffFragmentDrawing {
        if let existing = storage.attribute(.fragmentDrawing, at: location, effectiveRange: nil) as? DiffFragmentDrawing {
            return existing
        }
        let drawing = DiffFragmentDrawing()
        storage.addAttribute(.fragmentDrawing, value: drawing, range: NSRange(location: location, length: 1))
        return drawing
    }

    private func lastLine(from location: Int, in ns: NSString) -> NSRange {
        // The block's content runs to its first blank line.
        var line = ns.paragraphRange(for: NSRange(location: location, length: 0))
        while NSMaxRange(line) < ns.length {
            let next = ns.paragraphRange(for: NSRange(location: NSMaxRange(line), length: 0))
            if ns.substring(with: next).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            line = next
        }
        return line
    }

    private var columnWidth: CGFloat {
        guard let container = textView?.textContainer else { return 600 }
        return max(100, container.size.width - container.lineFragmentPadding * 2)
    }

    // MARK: Ghost text

    struct RenderedGhost {
        let string: NSAttributedString
        let height: CGFloat
    }

    private var ghostCache: [String: RenderedGhost] = [:]

    /// The removed Markdown, set in the editor's fonts with its syntax shown
    /// (like the native editor shows it at the caret), removed words marked.
    private func render(_ ghost: Ghost, width: CGFloat) -> RenderedGhost {
        let key = "\(width)|\(fontName)|\(fontSize)|\(ghost.removedWords.map { "\($0.location),\($0.length)" })|" + ghost.text
        if let cached = ghostCache[key] { return cached }
        if ghostCache.count > 200 { ghostCache.removeAll() }
        let fontName = self.fontName, fontSize = self.fontSize
        let body = NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
        let mono = NSFont.monospacedSystemFont(ofSize: fontSize * 0.88, weight: .regular)
        let out = NSMutableAttributedString()
        let ns = ghost.text as NSString
        var inFence = false
        var lastBlank = false
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, range, enclosing, _ in
            let line = ns.substring(with: range) as NSString
            let trimmed = (line as String).trimmingCharacters(in: .whitespaces)
            // Fence lines aren't shown, like in the editor away from the caret.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); return }
            if trimmed.isEmpty, !inFence {
                if lastBlank { return }
                lastBlank = true
            } else { lastBlank = false }
            // Line-start syntax shown the way the editor renders it.
            var font = body
            var skip = 0                    // UTF-16 units of syntax dropped
            var prefix = ""                 // what replaces them
            var indent: CGFloat = 0
            let leading = (line as String).prefix { $0 == " " || $0 == "\t" }.utf16.count
            if inFence {
                font = mono
            } else if let level = Self.headingLevel(trimmed) {
                let multipliers: [CGFloat] = [2.0, 1.5, 1.25, 1.07, 1.0, 0.92]
                let size = fontSize * multipliers[level - 1]
                font = NSFontManager.shared.convert(NSFont(name: fontName, size: size) ?? .systemFont(ofSize: size), toHaveTrait: .boldFontMask)
                skip = leading + level + ((line as String).dropFirst(leading + level).prefix { $0 == " " }.utf16.count)
            } else if let marker = Self.listMarker(line, at: leading) {
                skip = leading + marker.length
                prefix = marker.display
                indent = CGFloat(leading / 2 + 1) * fontSize * 1.1
            } else if trimmed.hasPrefix(">") {
                skip = leading + 1 + ((line as String).dropFirst(leading + 1).prefix { $0 == " " }.utf16.count)
                prefix = "\u{2502} "
            }
            let style = NSMutableParagraphStyle()
            style.lineSpacing = fontSize * 0.3
            style.paragraphSpacing = trimmed.isEmpty ? 0 : fontSize * 0.15
            style.firstLineHeadIndent = indent
            style.headIndent = indent + (prefix.isEmpty ? 0 : fontSize * 1.1)
            let start = out.length
            let shown = prefix + line.substring(from: min(skip, line.length)) + (NSMaxRange(enclosing) > NSMaxRange(range) ? "\n" : "")
            out.append(NSAttributedString(string: shown, attributes: [
                .font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
            ]))
            // Removed words in this line, shifted to where they landed in `out`.
            let prefixLength = (prefix as NSString).length
            for word in ghost.removedWords {
                let clipped = NSIntersectionRange(word, range)
                guard clipped.length > 0 else { continue }
                var local = clipped.location - range.location - skip
                var length = clipped.length
                if local < 0 { length += local; local = 0 }
                guard length > 0 else { continue }
                let target = NSRange(location: start + prefixLength + local, length: length)
                guard NSMaxRange(target) <= out.length else { continue }
                out.addAttributes([.backgroundColor: Self.removedWordColor,
                                   .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                   .strikethroughColor: NSColor.systemRed.withAlphaComponent(0.7)], range: target)
            }
        }
        // No trailing newline: it would add an empty line to the height.
        while out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        let bounds = out.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading])
        let rendered = RenderedGhost(string: out, height: ceil(bounds.height))
        ghostCache[key] = rendered
        return rendered
    }

    /// A list marker at `at` ("- ", "1. ", "- [x] "): its length and how it's shown.
    private static func listMarker(_ line: NSString, at: Int) -> (length: Int, display: String)? {
        let rest = line.substring(from: at)
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            let after = rest.dropFirst(2)
            if after.hasPrefix("[ ] ") { return (6, "\u{2610} ") }
            if after.hasPrefix("[x] ") || after.hasPrefix("[X] ") { return (6, "\u{2611} ") }
            return (2, "\u{2022} ")
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let dot = after.first, dot == "." || dot == ")", after.dropFirst().first == " " else { return nil }
        return (digits.count + 2, "\(digits)\(dot) ")
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        return rest.isEmpty || rest.first == " " ? hashes : nil
    }

    // MARK: Colors and metrics

    static let ghostPadding: CGFloat = 6
    static let ghostGap: CGFloat = 8
    static let addedWordColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.systemGreen.withAlphaComponent(0.34) : NSColor.systemGreen.withAlphaComponent(0.3)
    }
    static let removedWordColor = NSColor.systemRed.withAlphaComponent(0.26)
    static let addedBackground = NSColor.systemGreen.withAlphaComponent(0.11)
    static let removedBackground = NSColor(name: nil) { _ in
        NSColor.textBackgroundColor.blended(withFraction: 0.09, of: .systemRed) ?? .textBackgroundColor
    }
}

extension NSAttributedString.Key {
    /// Space a ghost opened above/below a line (so it's never added twice).
    static let diffSpaceAbove = NSAttributedString.Key("MarginDiffSpaceAbove")
    static let diffSpaceBelow = NSAttributedString.Key("MarginDiffSpaceBelow")
}

/// What one paragraph's fragment draws for the changes: a green tint behind
/// an added line, and removed text in the space opened above (or below) it.
@MainActor
final class DiffFragmentDrawing: NSObject, MarkdownFragmentDrawing {
    var tint = false
    var ghostAbove: NativeDiffDecorator.RenderedGhost?
    var ghostBelow: NativeDiffDecorator.RenderedGhost?

    // The text view ends where the column does: anything drawn outside it
    // is clipped, and the text starts right at the edge, so no side bar.
    func surface(in g: MarkdownFragmentGeometry) -> CGRect {
        var rect = CGRect(x: g.columnLeft, y: g.frame.minY, width: g.columnWidth, height: g.frame.height)
        // The last paragraph's spacing below may not count toward its frame.
        if let ghost = ghostBelow {
            rect = rect.union(CGRect(x: g.columnLeft, y: g.textBottom, width: g.columnWidth,
                                     height: ghost.height + NativeDiffDecorator.ghostPadding * 2 + NativeDiffDecorator.ghostGap))
        }
        return rect
    }

    func draw(in g: MarkdownFragmentGeometry) {
        if tint {
            let rect = CGRect(x: g.columnLeft, y: g.textTop - 2, width: g.columnWidth, height: g.textBottom - g.textTop + 4)
            NativeDiffDecorator.addedBackground.setFill()
            rect.fill()
        }
        if let ghost = ghostAbove {
            draw(ghost, top: g.frame.minY + NativeDiffDecorator.ghostGap / 2, g: g)
        }
        if let ghost = ghostBelow {
            draw(ghost, top: g.textBottom + NativeDiffDecorator.ghostGap / 2, g: g)
        }
    }

    private func draw(_ ghost: NativeDiffDecorator.RenderedGhost, top: CGFloat, g: MarkdownFragmentGeometry) {
        let pad = NativeDiffDecorator.ghostPadding
        let rect = CGRect(x: g.columnLeft, y: top, width: g.columnWidth, height: ghost.height + pad * 2)
        // Opaque: a code block's background may be under it.
        NativeDiffDecorator.removedBackground.setFill()
        rect.fill()
        ghost.string.draw(with: CGRect(x: g.columnLeft + g.padding, y: top + pad,
                                       width: g.columnWidth - g.padding * 2, height: ghost.height + 1),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}
