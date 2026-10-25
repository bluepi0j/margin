import Foundation

/// Decides where an "open" goes, VS Code style:
/// one folder = one window, files = tabs, never a window per file.
public enum OpenRouter {
    /// What the router needs to know about each open window.
    public struct WindowInfo: Equatable {
        public let id: Int
        public let folder: URL?
        public let openFiles: [URL]
        /// All tabs, including untitled ones that have no URL.
        public let tabCount: Int

        public init(id: Int, folder: URL?, openFiles: [URL], tabCount: Int? = nil) {
            self.id = id
            self.folder = folder
            self.openFiles = openFiles
            self.tabCount = tabCount ?? openFiles.count
        }

        /// A window with no folder and no tabs can be reused for anything.
        public var isEmpty: Bool { folder == nil && tabCount == 0 }
    }

    public enum Decision: Equatable {
        /// The file is already open: select its tab.
        case focusTab(window: Int, file: URL)
        /// Open the file as a new tab in this window.
        case openTab(window: Int, file: URL)
        /// The folder is already open in a window: bring it forward.
        case focusWindow(Int)
        /// Turn this empty window into the folder's window.
        case adoptFolder(window: Int, folder: URL)
        /// Make a new window (for a folder, or a file when no window exists).
        case newWindow(folder: URL?, file: URL?)
    }

    /// - Parameters:
    ///   - windows: open windows, front-most first.
    ///   - keyWindow: the window the user is looking at, if any.
    public static func route(_ url: URL, isDirectory: Bool, windows: [WindowInfo], keyWindow: Int?) -> Decision {
        let target = url.standardizedFileURL
        if isDirectory {
            if let w = windows.first(where: { $0.folder.map(same(target)) == true }) {
                return .focusWindow(w.id)
            }
            let key = windows.first { $0.id == keyWindow } ?? windows.first
            if let key, key.isEmpty {
                return .adoptFolder(window: key.id, folder: target)
            }
            return .newWindow(folder: target, file: nil)
        }

        // Already open somewhere: prefer the key window's copy.
        let ordered = orderedKeyFirst(windows, keyWindow)
        if let w = ordered.first(where: { $0.openFiles.contains(where: same(target)) }) {
            return .focusTab(window: w.id, file: target)
        }
        // Inside an open project: that project's window (deepest folder wins).
        let owners = ordered.filter { $0.folder.map { target.isInside($0) } == true }
        if let w = owners.max(by: { ($0.folder?.pathComponents.count ?? 0) < ($1.folder?.pathComponents.count ?? 0) }) {
            return .openTab(window: w.id, file: target)
        }
        // Otherwise: a new tab in the window in front.
        if let w = ordered.first {
            return .openTab(window: w.id, file: target)
        }
        return .newWindow(folder: nil, file: target)
    }

    private static func orderedKeyFirst(_ windows: [WindowInfo], _ key: Int?) -> [WindowInfo] {
        guard let key, let i = windows.firstIndex(where: { $0.id == key }) else { return windows }
        var copy = windows
        let w = copy.remove(at: i)
        return [w] + copy
    }

    private static func same(_ a: URL) -> (URL) -> Bool {
        let p = a.standardizedFileURL.resolvingSymlinksInPath().path
        return { $0.standardizedFileURL.resolvingSymlinksInPath().path == p }
    }
}
