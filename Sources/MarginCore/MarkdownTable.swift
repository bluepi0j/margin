import Foundation

/// A GFM pipe table in the text, and the edits the native editor offers on it
/// (add / delete rows and columns, tidy, Tab to the next cell). Every edit
/// rewrites the whole table with its columns padded to line up.
public struct MarkdownTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable { case none, left, center, right }

    /// The table's lines, from the first `|` to the end of the last row (no trailing newline).
    public let range: NSRange
    /// Header first, then the body rows (the separator line isn't one).
    public var rows: [[String]]
    public var alignments: [Alignment]
    /// Where the caret is: row index into `rows`, and column.
    public let caretRow: Int
    public let caretColumn: Int
    /// The line break between rows, as the text uses it ("\n" or "\r\n").
    let newline: String

    public var columnCount: Int { alignments.count }

    public enum Operation: Sendable {
        case addRowAbove, addRowBelow, addColumnLeft, addColumnRight, deleteRow, deleteColumn, tidy
    }

    // MARK: Finding

    /// The table the caret is in, if any.
    public static func at(_ caret: Int, in text: String) -> MarkdownTable? {
        let ns = text as NSString
        guard ns.length > 0, MarkdownEditing.codeFence(containing: caret, in: text) == nil else { return nil }
        let caret = min(caret, ns.length)
        let caretLine = ns.lineRange(for: NSRange(location: caret, length: 0))
        guard isRow(ns.substring(with: caretLine)) else { return nil }

        // Grow to the contiguous run of `|` lines around the caret.
        var start = caretLine.location
        while start > 0 {
            let prev = ns.lineRange(for: NSRange(location: start - 1, length: 0))
            guard isRow(ns.substring(with: prev)) else { break }
            start = prev.location
        }
        var lines: [NSRange] = []
        var location = start
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            guard isRow(ns.substring(with: line)) else { break }
            lines.append(line)
            location = NSMaxRange(line)
        }
        guard lines.count >= 2 else { return nil }
        let texts = lines.map { ns.substring(with: $0).trimmingCharacters(in: .newlines) }
        guard let alignments = separator(texts[1]) else { return nil }

        var rows = ([texts[0]] + texts.dropFirst(2)).map(cells)
        let columns = max(alignments.count, rows.map(\.count).max() ?? 0)
        rows = rows.map { $0 + Array(repeating: "", count: columns - $0.count) }

        // The line the caret is on, counting a caret at the very end of the last row as on it.
        let lineIndex = lines.lastIndex { $0.location <= caret } ?? 0
        let before = ns.substring(with: NSRange(location: lines[lineIndex].location, length: caret - lines[lineIndex].location))
        let column = max(0, min(columns - 1, pipeCount(before) - (texts[lineIndex].trimmingCharacters(in: .whitespaces).hasPrefix("|") ? 1 : 0)))
        let row = min(rows.count - 1, lineIndex == 0 ? 0 : max(1, lineIndex - 1))   // the separator counts as the first body row

        // Stop before the last row's line break, whether it is "\n" or "\r\n".
        var end = 0
        ns.getLineStart(nil, end: nil, contentsEnd: &end, for: lines[lines.count - 1])
        let newline = (ns.substring(with: lines[0]) as NSString).hasSuffix("\r\n") ? "\r\n" : "\n"
        return MarkdownTable(range: NSRange(location: start, length: end - start), rows: rows,
                             alignments: alignments + Array(repeating: .none, count: columns - alignments.count),
                             caretRow: row, caretColumn: column, newline: newline)
    }

    // MARK: Editing

    /// The edit that applies `operation`, and where the caret goes afterwards.
    public func applying(_ operation: Operation) -> (edit: MarkdownEditing.Edit, caret: Int) {
        var table = self
        var row = caretRow, column = caretColumn
        let blank = Array(repeating: "", count: columnCount)
        switch operation {
        case .addRowAbove:
            let at = max(1, row)                       // never above the header
            table.rows.insert(blank, at: at); row = at
        case .addRowBelow:
            table.rows.insert(blank, at: row + 1); row += 1
        case .addColumnLeft, .addColumnRight:
            let at = operation == .addColumnLeft ? column : column + 1
            for i in table.rows.indices { table.rows[i].insert("", at: at) }
            table.alignments.insert(.none, at: at); column = at
        case .deleteRow:
            if row == 0 || rows.count <= 2 { return tidied(table, row: row, column: column) }
            table.rows.remove(at: row); row = min(row, table.rows.count - 1)
        case .deleteColumn:
            if columnCount <= 1 { return tidied(table, row: row, column: column) }
            for i in table.rows.indices { table.rows[i].remove(at: column) }
            table.alignments.remove(at: column); column = min(column, table.columnCount - 1)
        case .tidy:
            break
        }
        return tidied(table, row: row, column: column)
    }

    /// Tab: the next cell (adding a row after the last one); ⇧Tab: the previous.
    /// The edit's selection covers the cell's text, so typing replaces it.
    public func movingToCell(forward: Bool) -> (edit: MarkdownEditing.Edit, caret: Int) {
        var table = self
        var row = caretRow, column = caretColumn + (forward ? 1 : -1)
        if column >= columnCount { column = 0; row += 1 }
        if column < 0 { column = columnCount - 1; row = max(0, row - 1) }
        if row >= rows.count { table.rows.append(Array(repeating: "", count: columnCount)) }
        return tidied(table, row: row, column: column, selectingCell: true)
    }

    private func tidied(_ table: MarkdownTable, row: Int, column: Int,
                        selectingCell: Bool = false) -> (edit: MarkdownEditing.Edit, caret: Int) {
        let (text, cellStarts) = table.formatted()
        let r = min(row, cellStarts.count - 1), c = min(column, table.columnCount - 1)
        let caret = range.location + cellStarts[r][c]
        let length = selectingCell ? (table.rows[r][c] as NSString).length : 0
        return (MarkdownEditing.Edit(range: range, text: text, selection: NSRange(location: caret, length: length)), caret)
    }

    /// The table as aligned Markdown, plus each cell's text offset (rows as in `rows`).
    func formatted() -> (text: String, cellStarts: [[Int]]) {
        let widths = (0..<columnCount).map { c in max(3, rows.map { Self.width($0[c]) }.max() ?? 0) }
        var out = ""
        var starts: [[Int]] = []
        func line(_ cells: [String]) {
            var rowStarts: [Int] = []
            out += "|"
            for (c, cell) in cells.enumerated() {
                out += " "
                rowStarts.append((out as NSString).length)
                out += cell + String(repeating: " ", count: widths[c] - Self.width(cell)) + " |"
            }
            starts.append(rowStarts)
            out += newline
        }
        line(rows[0])
        out += "|" + alignments.enumerated().map { c, a in
            let dashes = String(repeating: "-", count: widths[c] - (a == .center ? 2 : a == .none ? 0 : 1))
            switch a {
            case .none: return " \(dashes) "
            case .left: return " :\(dashes) "
            case .right: return " \(dashes): "
            case .center: return " :\(dashes): "
            }
        }.joined(separator: "|") + "|" + newline
        for r in rows.dropFirst() { line(r) }
        out.removeLast()                               // no newline after the last row ("\r\n" is one Character)
        return (out, starts)
    }

    // MARK: Parsing helpers

    private static func isRow(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
    }

    private static func separator(_ line: String) -> [Alignment]? {
        let parts = cells(line)
        guard !parts.isEmpty else { return nil }
        var out: [Alignment] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy({ "-:".contains($0) }), p.contains("-") else { return nil }
            switch (p.hasPrefix(":"), p.hasSuffix(":")) {
            case (true, true): out.append(.center)
            case (true, false): out.append(.left)
            case (false, true): out.append(.right)
            default: out.append(.none)
            }
        }
        return out
    }

    /// The trimmed cells of a row; `\|` and pipes inside `code` stay in the cell.
    static func cells(_ line: String) -> [String] {
        var trimmed = Substring(line.trimmingCharacters(in: .whitespaces))
        if trimmed.hasPrefix("|") { trimmed = trimmed.dropFirst() }
        if trimmed.hasSuffix("|") && !trimmed.hasSuffix("\\|") { trimmed = trimmed.dropLast() }
        var cells: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for ch in trimmed {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { current.append(ch); escaped = true; continue }
            if ch == "`" { inCode.toggle() }
            if ch == "|" && !inCode { cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(ch)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func pipeCount(_ text: String) -> Int {
        var count = 0, inCode = false, escaped = false
        for ch in text {
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "`" { inCode.toggle() }
            if ch == "|" && !inCode { count += 1 }
        }
        return count
    }

    /// Columns a string takes in a monospaced editor: CJK and other wide characters count twice.
    static func width(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { total, u in
            let v = u.value
            let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
                || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
                || (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1FAFF).contains(v)
            return total + (u.properties.generalCategory == .nonspacingMark ? 0 : wide ? 2 : 1)
        }
    }
}
