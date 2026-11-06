import Foundation

public enum TabTitles {
    /// Short titles for tabs. Files with the same name get the nearest
    /// differing parent folder as a hint, e.g. "todo.md — work".
    /// Returns (title, hint) in the same order as `urls`.
    ///
    /// With a `folder` open, a file outside it is a visitor: its hint is
    /// where it lives ("~/Downloads"), like VS Code's tab descriptions.
    public static func titles(for urls: [URL?], untitledNames: [String?], folder: URL? = nil,
                              home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [(title: String, hint: String?)] {
        let names = urls.map { $0?.lastPathComponent }
        return urls.indices.map { i in
            guard let url = urls[i], let name = names[i] else {
                return (untitledNames[i] ?? "Untitled", nil)
            }
            if let folder, !url.isInside(folder) {
                return (name, abbreviated(url.deletingLastPathComponent(), home: home))
            }
            let clashes = urls.indices.filter { $0 != i && names[$0] == name }.compactMap { urls[$0] }
            guard !clashes.isEmpty else { return (name, nil) }
            // Without the root "/" component, which would join as "//a".
            let parents = { (u: URL) in Array(u.deletingLastPathComponent().pathComponents.filter { $0 != "/" }.reversed()) }
            let mine = parents(url)
            // Walk up until our parent chain differs from every clash.
            for depth in 1...max(1, mine.count) {
                let suffix = Array(mine.prefix(depth))
                let unique = clashes.allSatisfy { other in Array(parents(other).prefix(depth)) != suffix }
                if unique || depth == mine.count {
                    return (name, suffix.isEmpty ? nil : suffix.reversed().joined(separator: "/"))
                }
            }
            return (name, nil)
        }
    }

    /// A folder path with the home folder written as "~".
    static func abbreviated(_ folder: URL, home: URL) -> String {
        let path = folder.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }
}
