import Foundation

public enum TabTitles {
    /// Short titles for tabs. Files with the same name get the nearest
    /// differing parent folder as a hint, e.g. "todo.md — work".
    /// Returns (title, hint) in the same order as `urls`.
    public static func titles(for urls: [URL?], untitledNames: [String?]) -> [(title: String, hint: String?)] {
        let names = urls.map { $0?.lastPathComponent }
        return urls.indices.map { i in
            guard let url = urls[i], let name = names[i] else {
                return (untitledNames[i] ?? "Untitled", nil)
            }
            let clashes = urls.indices.filter { $0 != i && names[$0] == name }.compactMap { urls[$0] }
            guard !clashes.isEmpty else { return (name, nil) }
            let mine = Array(url.deletingLastPathComponent().pathComponents.reversed())
            // Walk up until our parent chain differs from every clash.
            for depth in 1...max(1, mine.count) {
                let suffix = Array(mine.prefix(depth))
                let unique = clashes.allSatisfy { other in
                    Array(other.deletingLastPathComponent().pathComponents.reversed().prefix(depth)) != suffix
                }
                if unique || depth == mine.count {
                    return (name, suffix.reversed().joined(separator: "/"))
                }
            }
            return (name, nil)
        }
    }
}
