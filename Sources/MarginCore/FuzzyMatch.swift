import Foundation

/// Subsequence matching for Quick Open (⌘P).
public enum FuzzyMatch {
    /// Higher is better; nil means no match. Matches in the file name, at word
    /// starts and in runs score higher than scattered matches in folders.
    public static func score(_ query: String, path: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        if q.isEmpty { return 0 }
        let p = Array(path.lowercased())
        let original = Array(path)
        let nameStart = (path.lastIndex(of: "/").map { path.distance(from: path.startIndex, to: $0) + 1 }) ?? 0

        var score = 0
        var qi = 0
        var last = -2
        for (i, ch) in p.enumerated() where qi < q.count {
            guard ch == q[qi] else { continue }
            var s = 1
            if i == last + 1 { s += 5 }                       // consecutive
            if i >= nameStart { s += 3 }                      // in file name
            if i == nameStart { s += 8 }                      // file name start
            if i > 0, "/-_ .".contains(p[i - 1]) { s += 4 }   // word start
            if i > 0, original[i].isUppercase, original[i - 1].isLowercase { s += 3 } // camelCase
            score += s
            last = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        return score * 100 - p.count   // shorter paths win ties
    }

    /// Sorts `paths` by score for `query`, dropping non-matches.
    public static func rank(_ query: String, paths: [String], limit: Int = 50) -> [String] {
        paths.compactMap { p in score(query, path: p).map { (p, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .prefix(limit)
            .map(\.0)
    }
}
