import Foundation
import MarginCore
import Observation

/// One open document in a window's tab bar.
@MainActor @Observable
final class Tab: Identifiable {
    /// Also the document id inside the editor page.
    let id = UUID().uuidString
    /// nil for an untitled document that was never saved.
    var url: URL?
    var untitledName: String?
    /// Latest text from the editor that is not yet on disk.
    var unsavedText: String?
    /// The text we believe is on disk (to ignore our own writes in the watcher).
    var diskText: String?
    /// The file vanished from disk while open.
    var isMissing = false
    /// The file changed on disk while this tab had unsaved edits.
    var hasConflict = false
    /// Last save error, shown in the banner.
    var saveError: String?
    /// Edited in the editor but the content hasn't arrived yet.
    var isEditing = false
    /// Created by ⌘N as "Untitled.md": renamed after its first line once the
    /// user moves on, like Scratch names notes.
    var autoName = false

    init(url: URL?, untitledName: String? = nil, diskText: String? = nil) {
        self.url = url
        self.untitledName = untitledName
        self.diskText = diskText
    }

    var isUntitled: Bool { url == nil }
    var isDraft: Bool { Drafts.isDraft(url) }
    /// Shows the "unsaved" dot.
    var isDirty: Bool { unsavedText != nil && (isUntitled || saveError != nil || isMissing || hasConflict || !Preferences.shared.autosave) }
    var displayName: String {
        if isDraft { return DocumentTitle.from(markdown: unsavedText ?? diskText ?? "") ?? "Untitled" }
        return url?.lastPathComponent ?? untitledName ?? "Untitled"
    }
}

/// State of one window: its folder (if any), tabs and sidebar.
@MainActor @Observable
final class Workspace {
    var folder: URL?
    var tree: [FileNode] = []
    /// Expanded sidebar folders, by `pathKey`.
    var expanded: Set<String> = []
    var tabs: [Tab] = []
    var activeTabID: String?
    var selection = EditorSelection()
    var isQuickOpenVisible = false
    var sourceMode = false
    /// Focus mode (⇧⌘↩): sidebar, toolbar and tabs hidden.
    var focusMode = false
    /// Mirrors the split view, so the header can make room for the traffic lights.
    var sidebarCollapsed = false
    /// Headings of the active document, for the sidebar outline.
    var outline: [OutlineItem] = []
    var wordCount = 0
    var sidebarMode: SidebarMode = .files
    /// Project search (⇧⌘F).
    var searchQuery = ""
    var searchResults: [ProjectSearch.Match] = []
    var isSearching = false
    /// Bumped to move keyboard focus into the search field.
    var searchFocusRequest = 0

    enum SidebarMode: String { case files, outline, search }

    init(folder: URL?) {
        self.folder = folder
    }

    var activeTab: Tab? { tabs.first { $0.id == activeTabID } }
    var activeIndex: Int? { tabs.firstIndex { $0.id == activeTabID } }

    func tab(id: String) -> Tab? { tabs.first { $0.id == id } }

    func tab(for url: URL) -> Tab? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return tabs.first { $0.url?.standardizedFileURL.resolvingSymlinksInPath().path == path }
    }

    var title: String {
        folder?.lastPathComponent ?? activeTab?.displayName ?? "Margin"
    }

    /// "Untitled", "Untitled 2", ... not used by another tab here.
    func nextUntitledName() -> String {
        let used = Set(tabs.compactMap(\.untitledName))
        if !used.contains("Untitled") { return "Untitled" }
        var n = 2
        while used.contains("Untitled \(n)") { n += 1 }
        return "Untitled \(n)"
    }

    /// All Markdown files in the project, relative paths, for Quick Open.
    var projectFiles: [(path: String, url: URL)] {
        guard let folder else { return tabs.compactMap { t in t.url.map { ($0.lastPathComponent, $0) } } }
        return tree.flatMap(\.allFiles).map { ($0.relativePath(from: folder), $0) }
    }
}
