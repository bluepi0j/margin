import Foundation

/// One entry in the sidebar's file tree.
public struct FileNode: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let isDirectory: Bool
    /// nil for files; possibly empty for folders.
    public var children: [FileNode]?

    public var name: String { url.lastPathComponent }

    public init(url: URL, isDirectory: Bool, children: [FileNode]? = nil) {
        self.url = url
        self.isDirectory = isDirectory
        self.children = children
    }

    /// All file URLs in this subtree, depth first.
    public var allFiles: [URL] {
        isDirectory ? (children ?? []).flatMap(\.allFiles) : [url]
    }
}

public enum FileTreeLoader {
    /// Scans `root` for Markdown files.
    /// - Parameters:
    ///   - showAllFiles: include non-Markdown files too.
    ///   - maxEntries: stop after this many entries so a huge folder can't hang the app.
    public static func load(root: URL, showAllFiles: Bool = false, maxEntries: Int = 20_000) -> [FileNode] {
        var budget = maxEntries
        return scan(root, showAllFiles: showAllFiles, budget: &budget, depth: 0)
    }

    private static func scan(_ dir: URL, showAllFiles: Bool, budget: inout Int, depth: Int) -> [FileNode] {
        guard depth < 24, budget > 0 else { return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .isPackageKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        var folders: [FileNode] = []
        var files: [FileNode] = []
        for url in items {
            guard budget > 0 else { break }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isHidden == true { continue }
            if values?.isDirectory == true, values?.isPackage != true {
                if MarkdownFiles.ignoredFolders.contains(url.lastPathComponent) { continue }
                let children = scan(url, showAllFiles: showAllFiles, budget: &budget, depth: depth + 1)
                // Folders without any Markdown inside are noise; hide them.
                if children.isEmpty && !showAllFiles { continue }
                budget -= 1
                folders.append(FileNode(url: url, isDirectory: true, children: children))
            } else if showAllFiles || MarkdownFiles.isMarkdown(url) {
                budget -= 1
                files.append(FileNode(url: url, isDirectory: false))
            }
        }
        let order: (FileNode, FileNode) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return folders.sorted(by: order) + files.sorted(by: order)
    }
}
