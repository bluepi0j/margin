import Foundation

/// Which files the app treats as Markdown, and which folders it never shows.
public enum MarkdownFiles {
    public static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdx", "txt"]

    /// Folders skipped when scanning a project.
    public static let ignoredFolders: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", ".build", "build", "DerivedData", "Pods", ".venv", "venv",
        "__pycache__", ".next", ".nuxt", "dist", ".cache", ".idea", ".vscode", ".Trash",
    ]

    public static func isMarkdown(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    public static func isImage(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "tiff", "bmp", "avif"].contains(url.pathExtension.lowercased())
    }
}

public extension URL {
    /// Whether `self` is `folder` or lives somewhere inside it.
    func isInside(_ folder: URL) -> Bool {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let path = standardizedFileURL.resolvingSymlinksInPath().path
        return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// Path of `self` relative to `directory`, using `../` when needed.
    /// Used for image links so documents stay portable.
    func relativePath(from directory: URL) -> String {
        let target = standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let base = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        var common = 0
        while common < min(target.count, base.count) && target[common] == base[common] { common += 1 }
        let ups = Array(repeating: "..", count: base.count - common)
        return (ups + target[common...]).joined(separator: "/")
    }

    /// `self` as a Markdown link target relative to `directory`: spaces and
    /// parentheses, which would end the link, are percent-encoded.
    func markdownLinkPath(from directory: URL) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "()")
        let path = relativePath(from: directory)
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    /// Stable key for comparing file locations (no trailing slash, no `..`).
    var pathKey: String { standardizedFileURL.path }

    /// Path for comparing against FSEvents paths, which arrive as /private/tmp/…
    /// while the same folder may be known to us as /tmp/…. Works for files
    /// that no longer exist, unlike `resolvingSymlinksInPath()`.
    var canonicalPath: String {
        let path = standardizedFileURL.path
        for root in ["/private/tmp/", "/private/var/", "/private/etc/"] where path.hasPrefix(root) {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    var isDirectoryOnDisk: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
