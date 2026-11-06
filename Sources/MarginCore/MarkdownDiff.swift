import Foundation

/// What changed between two versions of a Markdown document, block by block
/// (paragraphs, headings, list items, code blocks, tables…), with the changed
/// words inside. Offsets are UTF-16, like NSString and the text views.
///
/// Every block owns a *segment*: its text plus the blank lines after it, up
/// to the next block. Segments tile the whole text, so a change is a run of
/// old segments replaced by a run of new ones, and restoring it is a plain
/// text replacement.
public enum MarkdownDiff {
    public struct Block: Equatable, Sendable {
        /// The block's text, without the blank lines after it.
        public let content: NSRange
        /// `content` plus the blank lines after it (the first block's segment
        /// also starts at 0).
        public let segment: NSRange
    }

    /// Where the removed text is shown in the current document.
    public enum GhostPlacement: Equatable, Sendable {
        /// Above the block whose content starts here.
        case before(Int)
        /// Below the block with this content range (removed at the very end).
        case after(NSRange)
    }

    public struct Hunk: Equatable, Sendable {
        /// The replaced segments in the committed text (empty: only additions,
        /// located where the old text would have been).
        public let old: NSRange
        /// The replacing segments in the current text (empty: only removals).
        public let new: NSRange
        /// The removed blocks' text, as shown in the ghost (no trailing blank lines).
        public let removedText: String
        /// Changed words within `removedText`.
        public let removedWords: [NSRange]
        /// Content ranges of the added or rewritten blocks in the current text.
        public let addedBlocks: [NSRange]
        /// Changed words in the current text.
        public let addedWords: [NSRange]
        /// Where to draw `removedText`; nil when nothing was removed.
        public let ghost: GhostPlacement?
    }

    // MARK: Blocks

    /// The top-level blocks of `text`. A block ends at a blank line; headings
    /// and top-level list items are blocks of their own; fenced code, math
    /// and front matter stay whole even across blank lines.
    public static func blocks(in text: NSString) -> [Block] {
        var contents: [NSRange] = []
        var start = -1          // content start of the open block
        var end = 0             // content end (after the last non-blank line)
        var fence: (char: unichar, count: Int)? = nil
        var inMath = false
        var inFrontMatter = false
        var lineStart = 0
        let length = text.length
        var lineIndex = 0
        // One copy of the text's code units, read directly below.
        var units = [UInt16](repeating: 0, count: length)
        units.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress, length > 0 { text.getCharacters(base, range: NSRange(location: 0, length: length)) }
        }

        func close() {
            if start >= 0 { contents.append(NSRange(location: start, length: end - start)) }
            start = -1
        }

        while lineStart < length {
            var lineEnd = lineStart
            while lineEnd < length, units[lineEnd] != 0x0A { lineEnd += 1 }
            let next = min(lineEnd + 1, length)
            let line = Line(units: units, start: lineStart, end: lineEnd)
            defer { lineStart = next; lineIndex += 1 }

            if inFrontMatter {
                end = lineEnd
                if line.isFrontMatterFence { inFrontMatter = false; close() }
                continue
            }
            if let open = fence {
                end = lineEnd
                if line.closesFence(open) { fence = nil; close() }
                continue
            }
            if inMath {
                end = lineEnd
                if line.isMathFence { inMath = false; close() }
                continue
            }
            if line.isBlank { close(); continue }

            if lineIndex == 0, line.isFrontMatterFence {
                start = lineStart; end = lineEnd; inFrontMatter = true
                continue
            }
            if let open = line.opensFence {
                close()
                start = lineStart; end = lineEnd; fence = open
                continue
            }
            if line.isMathFence {
                close()
                start = lineStart; end = lineEnd; inMath = true
                continue
            }
            if line.isHeading {
                close()
                contents.append(NSRange(location: lineStart, length: lineEnd - lineStart))
                continue
            }
            if line.startsTopLevelListItem { close() }
            if start < 0 { start = lineStart }
            end = lineEnd
        }
        close()

        var blocks: [Block] = []
        for (i, content) in contents.enumerated() {
            let segStart = i == 0 ? 0 : content.location
            let segEnd = i + 1 < contents.count ? contents[i + 1].location : length
            blocks.append(Block(content: content, segment: NSRange(location: segStart, length: segEnd - segStart)))
        }
        return blocks
    }

    // MARK: Diff

    public static func compute(base: String, current: String) -> [Hunk] {
        let old = base as NSString, new = current as NSString
        if base == current { return [] }
        let oldBlocks = blocks(in: old), newBlocks = blocks(in: new)
        let oldKeys = oldBlocks.map { key(old, $0) }, newKeys = newBlocks.map { key(new, $0) }
        let pairs = matches(oldKeys, newKeys)

        var hunks: [Hunk] = []
        var oi = 0, ni = 0
        for (mo, mn) in pairs + [(oldBlocks.count, newBlocks.count)] {
            if mo > oi || mn > ni {
                // Within the replaced run, a block rewritten into a similar
                // one is a change of its own.
                for (ro, rn) in refine(oldBlocks[oi..<mo], newBlocks[ni..<mn], old: old, new: new) {
                    hunks.append(hunk(oldBlocks[ro], newBlocks[rn], old: old, new: new,
                                      oldInsertAt: ro.upperBound < oldBlocks.count ? oldBlocks[ro.upperBound].segment.location : old.length,
                                      newInsertAt: rn.upperBound < newBlocks.count ? newBlocks[rn.upperBound].segment.location : new.length,
                                      nextNew: rn.upperBound < newBlocks.count ? newBlocks[rn.upperBound] : nil,
                                      previousNew: rn.lowerBound > 0 ? newBlocks[rn.lowerBound - 1] : nil))
                }
            }
            oi = mo + 1; ni = mn + 1
        }
        return hunks
    }

    /// Splits a replaced run where an old and a new block are the same kind
    /// and share most of their words: each such rewrite becomes its own
    /// change, the rest stay grouped. Index ranges, in document order.
    private static func refine(_ oldRun: ArraySlice<Block>, _ newRun: ArraySlice<Block>,
                               old: NSString, new: NSString) -> [(Range<Int>, Range<Int>)] {
        let whole = [(oldRun.startIndex..<oldRun.endIndex, newRun.startIndex..<newRun.endIndex)]
        guard !oldRun.isEmpty, !newRun.isEmpty, oldRun.count * newRun.count <= 2500 else { return whole }
        let a = Array(oldRun), b = Array(newRun)
        let ka = a.map { kind(old.substring(with: $0.content)) }, kb = b.map { kind(new.substring(with: $0.content)) }
        let wa = a.map { wordSet(old.substring(with: $0.content)) }, wb = b.map { wordSet(new.substring(with: $0.content)) }
        func similar(_ i: Int, _ j: Int) -> Bool {
            guard ka[i] == kb[j] else { return false }
            if wa[i].isEmpty || wb[j].isEmpty { return wa[i].isEmpty == wb[j].isEmpty }
            return wa[i].intersection(wb[j]).count * 2 >= max(wa[i].count, wb[j].count)
        }
        // LCS under `similar`.
        let n = a.count, m = b.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = similar(i, j) ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n, j < m {
            if similar(i, j), dp[i][j] == dp[i + 1][j + 1] + 1 { pairs.append((i, j)); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 } else { j += 1 }
        }
        guard !pairs.isEmpty else { return whole }
        let o = oldRun.startIndex, p = newRun.startIndex
        var out: [(Range<Int>, Range<Int>)] = []
        var oi = 0, ni = 0
        for (x, y) in pairs {
            if x > oi || y > ni { out.append(((o + oi)..<(o + x), (p + ni)..<(p + y))) }
            out.append(((o + x)..<(o + x + 1), (p + y)..<(p + y + 1)))
            oi = x + 1; ni = y + 1
        }
        if oi < n || ni < m { out.append(((o + oi)..<(o + n), (p + ni)..<(p + m))) }
        return out
    }

    /// The kind of block, from how it starts.
    private static func kind(_ content: String) -> Int {
        let line = content.drop { $0 == " " || $0 == "\t" }
        if line.hasPrefix("#") { return 1 }
        if line.hasPrefix("```") || line.hasPrefix("~~~") { return 2 }
        if line.hasPrefix("|") { return 3 }
        if line.hasPrefix(">") { return 4 }
        if line.hasPrefix("$$") { return 5 }
        if let first = line.first, "-*+".contains(first), line.dropFirst().first == " " { return 6 }
        if line.first?.isNumber == true, line.drop(while: \.isNumber).first.map({ $0 == "." || $0 == ")" }) == true { return 7 }
        return 0
    }

    private static func wordSet(_ s: String) -> Set<String> {
        let ns = s.lowercased() as NSString
        return Set(tokens(ns).map { ns.substring(with: $0) }.filter { $0.contains { $0.isLetter || $0.isNumber } })
    }

    /// The edit that puts a hunk's committed text back: replace `range` of
    /// the current text with `text`.
    public static func restore(_ hunk: Hunk, base: String, current: String) -> (range: NSRange, text: String) {
        let old = base as NSString, new = current as NSString
        var text = old.substring(with: hunk.old)
        if !text.isEmpty {
            // Old segments can lack the blank line the new neighbours need
            // (the old file's last block, say): keep blocks apart.
            let before = new.substring(to: hunk.new.location)
            if !before.isEmpty, !before.hasSuffix("\n\n") {
                text = (before.hasSuffix("\n") ? "\n" : "\n\n") + text
            }
            if NSMaxRange(hunk.new) < new.length, !text.hasSuffix("\n\n") {
                text += text.hasSuffix("\n") ? "\n" : "\n\n"
            }
        }
        return (hunk.new, text)
    }

    // MARK: Internals

    /// A block's text without surrounding whitespace, as UTF-16 code units:
    /// exact comparison (String's == normalizes Unicode, which is slow and
    /// not wanted here).
    private static func key(_ text: NSString, _ block: Block) -> [UInt16] {
        var start = block.content.location, end = NSMaxRange(block.content)
        func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
        while start < end, isSpace(text.character(at: start)) { start += 1 }
        while end > start, isSpace(text.character(at: end - 1)) { end -= 1 }
        var units = [UInt16](repeating: 0, count: end - start)
        units.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress { text.getCharacters(base, range: NSRange(location: start, length: end - start)) }
        }
        return units
    }

    /// Matched (old, new) index pairs, in order. Patience diff: blocks that
    /// occur once on both sides anchor the alignment, the runs between
    /// anchors are aligned recursively, and only small leftovers go through
    /// a full LCS — so big documents with scattered edits stay fast.
    static func matches<Key: Hashable>(_ a: [Key], _ b: [Key]) -> [(Int, Int)] {
        // Compare small integers, not paragraphs: same text, same id.
        var ids: [Key: Int] = [:]
        ids.reserveCapacity(a.count + b.count)
        let ia = a.map { key in ids[key] ?? { ids[key] = ids.count; return ids.count - 1 }() }
        let ib = b.map { key in ids[key] ?? { ids[key] = ids.count; return ids.count - 1 }() }
        var result: [(Int, Int)] = []
        result.reserveCapacity(min(a.count, b.count))
        var countA = [Int](repeating: 0, count: ids.count), countB = countA, indexB = countA
        align(ia, ib, 0..<a.count, 0..<b.count, &countA, &countB, &indexB, into: &result)
        return result
    }

    /// `countA`/`countB`/`indexB` are scratch tables indexed by id, left all
    /// zero between calls, so a call costs its range, not the document.
    private static func align(_ a: [Int], _ b: [Int], _ ra: Range<Int>, _ rb: Range<Int>,
                              _ countA: inout [Int], _ countB: inout [Int], _ indexB: inout [Int],
                              into result: inout [(Int, Int)]) {
        var lo = ra.lowerBound, loB = rb.lowerBound
        while lo < ra.upperBound, loB < rb.upperBound, a[lo] == b[loB] {
            result.append((lo, loB)); lo += 1; loB += 1
        }
        var hi = ra.upperBound, hiB = rb.upperBound
        var tail: [(Int, Int)] = []
        while hi > lo, hiB > loB, a[hi - 1] == b[hiB - 1] {
            hi -= 1; hiB -= 1; tail.append((hi, hiB))
        }
        defer { result += tail.reversed() }
        guard lo < hi, loB < hiB else { return }

        // Anchors: keys that occur exactly once in each run.
        for i in lo..<hi { countA[a[i]] += 1 }
        for j in loB..<hiB { countB[b[j]] += 1; indexB[b[j]] = j }
        var candidates: [(Int, Int)] = []
        for i in lo..<hi where countA[a[i]] == 1 && countB[a[i]] == 1 { candidates.append((i, indexB[a[i]])) }
        for i in lo..<hi { countA[a[i]] = 0 }
        for j in loB..<hiB { countB[b[j]] = 0 }
        let anchors = longestIncreasing(candidates)

        if anchors.isEmpty {
            let midA = Array(a[lo..<hi]), midB = Array(b[loB..<hiB])
            // Two rewrites sharing nothing unique: a full LCS only when small.
            guard midA.count * midB.count <= 250_000 else { return }
            let diff = midB.difference(from: midA)
            var removed = Set<Int>(), inserted = Set<Int>()
            for change in diff {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): inserted.insert(offset)
                }
            }
            let keptA = (0..<midA.count).filter { !removed.contains($0) }
            let keptB = (0..<midB.count).filter { !inserted.contains($0) }
            for (x, y) in zip(keptA, keptB) { result.append((lo + x, loB + y)) }
            return
        }
        var pa = lo, pb = loB
        for (i, j) in anchors {
            align(a, b, pa..<i, pb..<j, &countA, &countB, &indexB, into: &result)
            result.append((i, j))
            pa = i + 1; pb = j + 1
        }
        align(a, b, pa..<hi, pb..<hiB, &countA, &countB, &indexB, into: &result)
    }

    /// The longest run of pairs (already ordered by first index) whose
    /// second indices increase: patience sorting.
    private static func longestIncreasing(_ pairs: [(Int, Int)]) -> [(Int, Int)] {
        var tops: [Int] = []          // index into pairs of each pile's top
        var previous = [Int](repeating: -1, count: pairs.count)
        for (k, pair) in pairs.enumerated() {
            var low = 0, high = tops.count
            while low < high {
                let mid = (low + high) / 2
                if pairs[tops[mid]].1 < pair.1 { low = mid + 1 } else { high = mid }
            }
            if low > 0 { previous[k] = tops[low - 1] }
            if low == tops.count { tops.append(k) } else { tops[low] = k }
        }
        var out: [(Int, Int)] = []
        var k = tops.last ?? -1
        while k >= 0 { out.append(pairs[k]); k = previous[k] }
        return out.reversed()
    }

    private static func hunk(_ oldRun: ArraySlice<Block>, _ newRun: ArraySlice<Block>, old: NSString, new: NSString,
                             oldInsertAt: Int, newInsertAt: Int, nextNew: Block?, previousNew: Block?) -> Hunk {
        let oldSpan = oldRun.isEmpty ? NSRange(location: oldInsertAt, length: 0)
            : NSRange(location: oldRun.first!.segment.location, length: NSMaxRange(oldRun.last!.segment) - oldRun.first!.segment.location)
        let newSpan = newRun.isEmpty ? NSRange(location: newInsertAt, length: 0)
            : NSRange(location: newRun.first!.segment.location, length: NSMaxRange(newRun.last!.segment) - newRun.first!.segment.location)
        let removedRange = oldRun.isEmpty ? NSRange(location: 0, length: 0)
            : NSRange(location: oldRun.first!.content.location, length: NSMaxRange(oldRun.last!.content) - oldRun.first!.content.location)
        let removedText = oldRun.isEmpty ? "" : old.substring(with: removedRange)
        let addedRange = newRun.isEmpty ? nil
            : NSRange(location: newRun.first!.content.location, length: NSMaxRange(newRun.last!.content) - newRun.first!.content.location)

        var removedWords: [NSRange] = [], addedWords: [NSRange] = []
        if let addedRange, !removedText.isEmpty {
            (removedWords, addedWords) = words(removedText as NSString, new.substring(with: addedRange) as NSString)
            addedWords = addedWords.map { NSRange(location: $0.location + addedRange.location, length: $0.length) }
        }

        var ghost: GhostPlacement?
        if !oldRun.isEmpty {
            if let first = newRun.first { ghost = .before(first.content.location) }
            else if let nextNew { ghost = .before(nextNew.content.location) }
            else if let previousNew { ghost = .after(previousNew.content) }
        }
        return Hunk(old: oldSpan, new: newSpan, removedText: removedText, removedWords: removedWords,
                    addedBlocks: newRun.map(\.content), addedWords: addedWords, ghost: ghost)
    }

    /// Changed words between two rewrites of the same text, or nothing when
    /// they share too little for word marks to help.
    static func words(_ a: NSString, _ b: NSString) -> ([NSRange], [NSRange]) {
        let ta = tokens(a), tb = tokens(b)
        guard ta.count <= 5000, tb.count <= 5000 else { return ([], []) }
        let sa = ta.map { a.substring(with: $0) }, sb = tb.map { b.substring(with: $0) }
        let diff = sb.difference(from: sa)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        let common = sa.count - removed.count
        let isWord = { (s: String) in s.contains { !$0.isWhitespace } }
        let wordsA = sa.filter(isWord).count, wordsB = sb.filter(isWord).count
        let commonWords = sa.indices.filter { !removed.contains($0) && isWord(sa[$0]) }.count
        // Less than a third in common reads as a rewrite: the block marks say it all.
        guard common > 0, commonWords * 3 >= max(wordsA, wordsB) else { return ([], []) }
        return (merge(removed.sorted().filter { isWord(sa[$0]) }.map { ta[$0] }, gapsIn: a),
                merge(inserted.sorted().filter { isWord(sb[$0]) }.map { tb[$0] }, gapsIn: b))
    }

    /// Words (letters and digits), single CJK characters, single punctuation
    /// marks, and runs of whitespace.
    static func tokens(_ s: NSString) -> [NSRange] {
        var result: [NSRange] = []
        let str = s as String
        var i = str.startIndex
        while i < str.endIndex {
            let c = str[i]
            var j = str.index(after: i)
            if c.isWhitespace {
                while j < str.endIndex, str[j].isWhitespace { j = str.index(after: j) }
            } else if isWordCharacter(c) {
                while j < str.endIndex, isWordCharacter(str[j]) { j = str.index(after: j) }
            }
            result.append(NSRange(i..<j, in: str))
            i = j
        }
        return result
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        guard c.isLetter || c.isNumber || c == "_" || c == "'" else { return false }
        // CJK has no spaces: compare it character by character.
        guard let scalar = c.unicodeScalars.first else { return true }
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return false
        default: return true
        }
    }

    /// Adjacent ranges joined across the whitespace between them, so a
    /// changed phrase is one mark.
    private static func merge(_ ranges: [NSRange], gapsIn s: NSString) -> [NSRange] {
        var out: [NSRange] = []
        for r in ranges {
            if let last = out.last {
                let gap = NSRange(location: NSMaxRange(last), length: r.location - NSMaxRange(last))
                if gap.length >= 0, s.substring(with: gap).allSatisfy({ $0 == " " || $0 == "\t" }) {
                    out[out.count - 1] = NSRange(location: last.location, length: NSMaxRange(r) - last.location)
                    continue
                }
            }
            out.append(r)
        }
        return out
    }
}

/// One line of the text, for block splitting. Reads UTF-16 units in place:
/// no String per line (a 1 MB note has tens of thousands of lines).
private struct Line {
    let units: [UInt16]
    /// First and past-the-last non-blank units ("" when first == end).
    let first: Int
    let end: Int
    let indent: Int

    init(units: [UInt16], start: Int, end lineEnd: Int) {
        self.units = units
        var i = start, indent = 0
        while i < lineEnd {
            let c = units[i]
            if c == 0x20 { indent += 1 } else if c == 0x09 { indent += 4 } else { break }
            i += 1
        }
        var e = lineEnd
        while e > i, Line.isSpace(units[e - 1]) { e -= 1 }
        first = i
        end = e
        self.indent = indent
    }

    static func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A }

    private func at(_ offset: Int) -> unichar? {
        first + offset < end ? units[first + offset] : nil
    }

    /// How many times `c` repeats from the start of the body.
    private func run(of c: unichar, from offset: Int = 0) -> Int {
        var n = 0
        while at(offset + n) == c { n += 1 }
        return n
    }

    var isBlank: Bool { first >= end }
    var length: Int { end - first }
    var isFrontMatterFence: Bool { indent == 0 && length == 3 && run(of: 0x2D) == 3 }
    var isMathFence: Bool { length == 2 && run(of: 0x24) == 2 }

    var isHeading: Bool {
        guard indent < 4, at(0) == 0x23 else { return false }
        let hashes = run(of: 0x23)
        guard hashes <= 6 else { return false }
        guard let next = at(hashes) else { return true }
        return next == 0x20 || next == 0x09
    }

    var opensFence: (char: unichar, count: Int)? {
        guard indent < 4, let c = at(0), c == 0x60 || c == 0x7E else { return nil }
        let count = run(of: c)
        guard count >= 3 else { return nil }
        // A backtick fence's info string can't contain backticks.
        if c == 0x60 {
            for k in count..<length where at(k) == 0x60 { return nil }
        }
        return (c, count)
    }

    func closesFence(_ open: (char: unichar, count: Int)) -> Bool {
        guard indent < 4, at(0) == open.char else { return false }
        let count = run(of: open.char)
        guard count >= open.count else { return false }
        for k in count..<length where !(at(k) == 0x20 || at(k) == 0x09) { return false }
        return true
    }

    var startsTopLevelListItem: Bool {
        guard indent == 0, let c = at(0) else { return false }
        if c == 0x2D || c == 0x2A || c == 0x2B { return length == 1 || at(1) == 0x20 }
        var digits = 0
        while let d = at(digits), d >= 0x30, d <= 0x39 { digits += 1 }
        guard digits > 0, digits <= 9, let dot = at(digits), dot == 0x2E || dot == 0x29 else { return false }
        return length == digits + 1 || at(digits + 1) == 0x20
    }
}
