import AppKit
import MarginCore
import SwiftUI
import UniformTypeIdentifiers

/// One window: a folder (optional), its tabs, the sidebar and the editor.
/// Menu commands reach it through the responder chain.
@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate {
    let workspace: Workspace
    /// The editor for all tabs of this window (web or native, see Settings).
    private(set) var editor: DocumentEditor
    private var area: NSHostingController<EditorAreaView>!
    private var splitController: NSSplitViewController!
    private var sidebarItem: NSSplitViewItem!
    private var watcher: FileWatcher?
    /// The block-based observer for sidebar resizes; removed on close.
    private var splitObserver: NSObjectProtocol?
    private var treeReloadScheduled = false
    private var treeReloadID = UUID()
    private var treeShowsAllFiles = Preferences.shared.showAllFiles
    private var closeConfirmed = false
    private var isSwitchingEngine = false
    private var autosaveInUse = Preferences.shared.autosave
    /// Tabs whose close is in progress (a sheet may be up), so ⌘W twice doesn't queue two sheets.
    private var closingTabs: Set<String> = []

    /// Called when the window closes so the app can drop it.
    var onClose: ((WorkspaceWindowController) -> Void)?

    init(folder: URL?, editor: DocumentEditor? = nil) {
        workspace = Workspace(folder: folder)
        self.editor = editor ?? Self.makeEditor()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.minSize = NSSize(width: 560, height: 360)
        // Margin draws its own chrome (header, format bar, sidebar). An empty
        // toolbar only gives the title bar its height, so the traffic lights
        // sit centered in the header row.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.backgroundColor = .textBackgroundColor
        super.init(window: window)
        window.delegate = self

        buildContent()
        window.toolbar = NSToolbar(identifier: "MarginChrome")
        wireEditor()
        setSidebarCollapsed(folder == nil, animated: false)
        if let folder { NSDocumentController.shared.noteNewRecentDocumentURL(folder) }
        reloadTree()
        rewatch()
        updateTitle()
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: Preferences.didChange, object: nil)
        window.center()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func buildContent() {
        let sidebar = NSHostingController(rootView: SidebarView(workspace: workspace, actions: sidebarActions))
        sidebar.sizingOptions = []
        // A plain item, not a system sidebar: no vibrancy or glass, our own colors.
        sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = .defaultLow + 10

        let content = NSHostingController(rootView: makeAreaView())
        content.sizingOptions = []
        area = content
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 360

        splitController = NSSplitViewController()
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(contentItem)
        splitController.splitView.dividerStyle = .thin
        splitController.splitView.autosaveName = "MarginSplit"
        splitObserver = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification,
                                               object: splitController.splitView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSidebarState() }
        }
        window?.contentViewController = splitController
        window?.setContentSize(NSSize(width: 1120, height: 760))
    }

    private func makeAreaView() -> EditorAreaView {
        EditorAreaView(
            workspace: workspace, editorView: editor.view,
            tabActions: tabActions, bannerActions: bannerActions, startActions: startActions,
            chromeActions: ChromeActions(
                toggleSidebar: { [weak self] in self?.toggleSidebarVisibility(nil) },
                toggleSource: { [weak self] in self?.toggleSourceMode(nil) },
                run: { [weak self] command, args in self?.runCommand(command, args) },
                pickImage: { [weak self] in self?.insertImage(nil) }
            ),
            openFile: { [weak self] url in self?.openFile(url) }
        )
    }

    private func syncSidebarState() {
        if workspace.sidebarCollapsed != sidebarItem.isCollapsed { workspace.sidebarCollapsed = sidebarItem.isCollapsed }
    }

    private func setSidebarCollapsed(_ collapsed: Bool, animated: Bool = true) {
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                sidebarItem.animator().isCollapsed = collapsed
            }
        } else {
            sidebarItem.isCollapsed = collapsed
        }
        workspace.sidebarCollapsed = collapsed
    }

    private func wireEditor() {
        editor.onEvent = { [weak self] in self?.handle($0) }
        editor.savePastedImage = { [weak self] pb in self?.savePastedImage(from: pb) }
        if let web = editor as? WebDocumentEditor {
            web.onDropFiles = { [weak self] urls, point in self?.handleDrop(urls, at: point) ?? false }
        }
        editor.applySettings()
    }

    static func makeEditor() -> DocumentEditor {
        Preferences.shared.editorEngine == .native ? NativeDocumentEditor() : WebDocumentEditor()
    }

    private var engineInUse: Preferences.EditorEngine { editor is NativeDocumentEditor ? .native : .web }

    @objc private func preferencesChanged() {
        editor.applySettings()
        // Autosave just switched on: write what's pending, or the "unsaved"
        // dot would vanish with the text still only in memory.
        if Preferences.shared.autosave, !autosaveInUse {
            for tab in workspace.tabs where tab.unsavedText != nil && !tab.isMissing && !tab.hasConflict { write(tab) }
        }
        autosaveInUse = Preferences.shared.autosave
        if treeShowsAllFiles != Preferences.shared.showAllFiles {
            treeShowsAllFiles = Preferences.shared.showAllFiles
            reloadTree()
        }
        if Preferences.shared.editorEngine != engineInUse { Task { await switchEngine() } }
    }

    /// Swaps the web editor for the native one (or back), carrying every tab over.
    private func switchEngine() async {
        guard !isSwitchingEngine else { return }
        isSwitchingEngine = true
        defer { isSwitchingEngine = false }
        guard await flushEditor() else { return }
        guard Preferences.shared.editorEngine != engineInUse else { return }
        editor.onEvent = nil
        editor = Self.makeEditor()
        wireEditor()
        workspace.sourceMode = false
        area.rootView = makeAreaView()
        for tab in workspace.tabs {
            editor.open(id: tab.id, markdown: tab.unsavedText ?? tab.diskText ?? "", documentURL: tab.url, activate: false)
        }
        if let id = workspace.activeTabID { editor.activate(id: id) }
        focusEditor()
    }

    // MARK: Editor events

    private func handle(_ event: EditorEvent) {
        switch event {
        case .ready:
            // Fresh page (first load or after a crash): send every document again.
            editor.applySettings()
            for tab in workspace.tabs {
                // Edits not yet posted went down with the old page; don't let
                // them block closing and quitting forever.
                tab.isEditing = false
                editor.open(id: tab.id, markdown: tab.unsavedText ?? tab.diskText ?? "", documentURL: tab.url, activate: false)
            }
            if let id = workspace.activeTabID { editor.activate(id: id) }
        case .edited(let id):
            workspace.tab(id: id)?.isEditing = true
        case .content(let id, let markdown):
            guard let tab = workspace.tab(id: id) else { return }
            tab.isEditing = false
            accept(markdown, for: tab)
            if workspace.activeTabID != id { autoRename(tab) }
        case .selection(let state):
            workspace.selection = state
            workspace.sourceMode = state.sourceMode
            (editor as? WebDocumentEditor)?.selectionChanged(state)
        case .openLink(let href):
            openLink(href)
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .pickImage:
            insertImage(nil)
        case .outline(let items, let words):
            if workspace.outline != items { workspace.outline = items }
            workspace.wordCount = words
        }
    }

    /// New text from the editor: remember it, and autosave when allowed.
    private func accept(_ markdown: String, for tab: Tab) {
        if markdown == tab.diskText {
            tab.unsavedText = nil
            return
        }
        tab.unsavedText = markdown
        if Preferences.shared.autosave, tab.url != nil, !tab.isMissing, !tab.hasConflict {
            write(tab)
        }
    }

    @discardableResult
    private func write(_ tab: Tab, overwrite: Bool = false) -> Bool {
        guard let url = tab.url, let text = tab.unsavedText else { return true }
        do {
            // FSEvents is delayed. Check disk before autosaving so an edit made
            // by another app in that interval isn't silently overwritten.
            if !overwrite {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    tab.isMissing = true
                    return false
                }
                let current = try TextFile.read(url).text
                guard current == tab.diskText || current == text else {
                    tab.hasConflict = true
                    return false
                }
            }
            try TextFile.write(text, to: url)
            tab.diskText = text
            tab.unsavedText = nil
            tab.saveError = nil
            tab.isMissing = false
            return true
        } catch {
            tab.saveError = error.localizedDescription
            return false
        }
    }

    /// Pulls any not-yet-posted edits out of the page.
    @discardableResult
    func flushEditor() async -> Bool {
        let result = await editor.flush()
        for (id, markdown) in result {
            if let tab = workspace.tab(id: id) {
                tab.isEditing = false
                accept(markdown, for: tab)
            }
        }
        return !workspace.tabs.contains { $0.isEditing }
    }

    func runCommand(_ name: String, _ args: [String: Any] = [:]) {
        guard workspace.activeTab != nil else { return NSSound.beep() }
        editor.command(name, args: args)
    }

    // MARK: Tabs

    /// Opens `url` as a tab here (or selects its tab if already open).
    func openFile(_ url: URL, activate: Bool = true) {
        if let existing = workspace.tab(for: url) {
            if activate { select(existing.id) }
            return
        }
        let text: String
        do {
            text = try TextFile.read(url).text
        } catch {
            showError(error)
            return
        }
        let tab = Tab(url: url.standardizedFileURL, diskText: text)
        insert(tab, markdown: text, activate: activate)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        rewatch()
    }

    /// ⌘N. In a folder window this is a real "Untitled.md" in the folder; otherwise
    /// a draft in the app's support folder. Either way it is saved as you type.
    func newUntitled(text: String = "") {
        do {
            let url: URL
            if let folder = workspace.folder {
                // Next to the active file when it is inside the project, else at the root.
                let active = workspace.activeTab?.url
                let dir = active.flatMap { $0.isInside(folder) && !Drafts.isDraft($0) ? $0.deletingLastPathComponent() : nil } ?? folder
                url = TextFile.availableURL(in: dir, base: "Untitled", ext: "md")
                try TextFile.write(text, to: url)
                workspace.expanded.insert(dir.pathKey)
                reloadTree()
            } else {
                url = try Drafts.create()
                if !text.isEmpty { try TextFile.write(text, to: url) }
            }
            let tab = Tab(url: url.standardizedFileURL, diskText: text)
            tab.autoName = workspace.folder != nil
            insert(tab, markdown: text, activate: true)
            rewatch()
        } catch {
            // Fall back to an in-memory document.
            let tab = Tab(url: nil, untitledName: workspace.nextUntitledName())
            if !text.isEmpty { tab.unsavedText = text }
            insert(tab, markdown: text, activate: true)
        }
    }

    /// Gives an auto-named "Untitled.md" the name of its first line.
    private func autoRename(_ tab: Tab) {
        guard tab.autoName, tab.unsavedText == nil, !tab.isEditing, !tab.hasConflict, !tab.isMissing,
              let url = tab.url, FileManager.default.fileExists(atPath: url.path),
              url.deletingPathExtension().lastPathComponent.hasPrefix("Untitled"),
              let title = DocumentTitle.from(markdown: tab.diskText ?? "") else { return }
        let dir = url.deletingLastPathComponent()
        let target = TextFile.availableURL(in: dir, base: title, ext: url.pathExtension.isEmpty ? "md" : url.pathExtension)
        do {
            try FileManager.default.moveItem(at: url, to: target)
        } catch { return }
        tab.url = target.standardizedFileURL
        tab.autoName = false
        editor.moved(id: tab.id, documentURL: target)
        reloadTree()
        updateTitle()
    }

    private func insert(_ tab: Tab, markdown: String, activate: Bool) {
        // New tabs open to the right of the active one, like VS Code.
        if let i = workspace.activeIndex { workspace.tabs.insert(tab, at: i + 1) } else { workspace.tabs.append(tab) }
        let previous = activate ? workspace.activeTab : nil
        editor.open(id: tab.id, markdown: markdown, documentURL: tab.url, activate: activate)
        if activate {
            workspace.activeTabID = tab.id
            focusEditor()
        }
        // Native posts pending content while activating; Web posts it later.
        // Name only saved content, whichever editor finishes first.
        if let previous { autoRename(previous) }
        updateTitle()
    }

    func select(_ id: String) {
        guard workspace.tab(id: id) != nil else { return }
        if let previous = workspace.activeTab, previous.id != id { autoRename(previous) }
        workspace.activeTabID = id
        editor.activate(id: id)
        updateTitle()
        focusEditor()
    }

    private func focusEditor() {
        if let view = editor.focusView { window?.makeFirstResponder(view) }
        editor.focus()
    }

    /// Closes a tab, asking first if closing would lose work. Returns false if cancelled.
    @discardableResult
    func closeTab(_ id: String) async -> Bool {
        guard let tab = workspace.tab(id: id) else { return true }
        guard !closingTabs.contains(id) else { return false }
        closingTabs.insert(id)
        defer { closingTabs.remove(id) }
        guard await flushEditor() else { return false }
        if tab.isDraft {
            guard await resolveDraft(tab) else { return false }
        } else if tab.unsavedText != nil, !(await resolveUnsaved(tab)) {
            return false
        }
        autoRename(tab)
        removeIfEmptyUntitledFile(tab)
        remove(tab)
        return true
    }

    /// Closing a draft: empty ones just go away; others can be saved somewhere or deleted.
    private func resolveDraft(_ tab: Tab) async -> Bool {
        guard let url = tab.url else { return true }
        write(tab)
        // Judge emptiness by the newest text: if the last write failed, `diskText`
        // is stale and deleting the file would throw away what was typed.
        let text = tab.unsavedText ?? tab.diskText ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: url)
            return true
        }
        guard let window else { return false }
        select(tab.id)
        let alert = NSAlert()
        alert.messageText = "Keep “\(tab.displayName)”?"
        alert.informativeText = "This new document isn’t in a folder yet. Save it somewhere, or delete it."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        alert.buttons[2].hasDestructiveAction = true
        switch await alert.beginSheetModal(for: window) {
        case .alertFirstButtonReturn:
            return await saveAs(tab)
        case .alertThirdButtonReturn:
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return true
        default:
            return false
        }
    }

    /// An "Untitled.md" made with ⌘N (or a draft) closed without typing anything is removed again.
    private func removeIfEmptyUntitledFile(_ tab: Tab) {
        guard let url = tab.url, tab.isDraft || (tab.autoName && url.lastPathComponent.hasPrefix("Untitled")),
              (tab.unsavedText ?? tab.diskText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try? FileManager.default.removeItem(at: url)
        if !tab.isDraft { reloadTree() }
    }

    /// Empty new files and drafts go away when the window closes or the app
    /// quits. Called once every window has agreed to close, so a cancelled
    /// quit doesn't leave tabs pointing at deleted files.
    func removeEmptyUntitledFiles() {
        for tab in workspace.tabs { removeIfEmptyUntitledFile(tab) }
    }

    private func remove(_ tab: Tab) {
        guard let index = workspace.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        workspace.tabs.remove(at: index)
        editor.close(id: tab.id)
        if workspace.activeTabID == tab.id {
            workspace.activeTabID = nil
            if !workspace.tabs.isEmpty {
                select(workspace.tabs[min(index, workspace.tabs.count - 1)].id)
            } else {
                workspace.selection = EditorSelection()
            }
        }
        updateTitle()
        rewatch()
    }

    /// Unsaved content in a tab that is about to close: save, discard or cancel.
    private func resolveUnsaved(_ tab: Tab) async -> Bool {
        // With autosave on, a normal file just gets written. If that keeps
        // failing (a read-only file), the sheet below still offers a way out.
        if !tab.isUntitled, Preferences.shared.autosave, !tab.hasConflict, !tab.isMissing, write(tab) {
            return true
        }
        guard let window else { return false }
        select(tab.id)
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to “\(tab.displayName)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        alert.buttons[2].hasDestructiveAction = true
        switch await alert.beginSheetModal(for: window) {
        case .alertFirstButtonReturn: return await save(tab)
        case .alertThirdButtonReturn:
            tab.unsavedText = nil
            editor.reload(id: tab.id, markdown: tab.diskText ?? "")
            return true
        default: return false
        }
    }

    /// Asks about every tab with unsaved work. Used when closing the window or quitting.
    func prepareToClose(quitting: Bool = false) async -> Bool {
        guard await flushEditor() else { return false }
        for tab in workspace.tabs {
            if tab.isDraft {
                // Quitting keeps drafts (they come back next launch); closing the window asks.
                if quitting {
                    guard write(tab) else { select(tab.id); return false }
                } else if !(await resolveDraft(tab)) { return false }
            } else if tab.unsavedText != nil, !(await resolveUnsaved(tab)) {
                return false
            }
            autoRename(tab)
        }
        return true
    }

    // MARK: Saving

    @discardableResult
    func save(_ tab: Tab) async -> Bool {
        guard await flushEditor() else { return false }
        if tab.isUntitled || tab.isDraft { return await saveAs(tab) }
        if tab.unsavedText == nil, tab.isMissing { tab.unsavedText = tab.diskText ?? "" }
        let saved = write(tab, overwrite: true)
        if saved { tab.hasConflict = false }
        return saved
    }

    @discardableResult
    func saveAs(_ tab: Tab) async -> Bool {
        guard await flushEditor() else { return false }
        guard let window else { return false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = tab.isDraft || tab.url == nil ? "\(tab.displayName).md" : tab.url!.lastPathComponent
        panel.directoryURL = tab.isDraft ? (workspace.folder ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
            : (tab.url?.deletingLastPathComponent() ?? workspace.folder)
        panel.canCreateDirectories = true
        await waitForSheetToClose()
        guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return false }
        // Saving over an open tab would discard that tab's in-memory edits.
        let openWorkspaces = NSApp.windows.compactMap { ($0.windowController as? WorkspaceWindowController)?.workspace }
        if openWorkspaces.contains(where: { $0.tab(for: url).map { $0.id != tab.id } == true }) {
            await waitForSheetToClose()
            let alert = NSAlert()
            alert.messageText = "“\(url.lastPathComponent)” is already open."
            alert.informativeText = "Close its tab before replacing the file."
            await alert.beginSheetModal(for: window)
            return false
        }
        guard await flushEditor() else { return false }
        let original = tab.unsavedText ?? tab.diskText ?? ""
        var text = original
        if let draft = tab.url, Drafts.isDraft(draft) {
            // Pasted images were saved next to the draft; take them along.
            text = Drafts.relocateImages(in: text, from: draft.deletingLastPathComponent(), to: url.deletingLastPathComponent())
        }
        do {
            try TextFile.write(text, to: url)
        } catch {
            showError(error)
            return false
        }
        if let draft = tab.url, Drafts.isDraft(draft),
           draft.standardizedFileURL.resolvingSymlinksInPath() != url.standardizedFileURL.resolvingSymlinksInPath() {
            try? FileManager.default.removeItem(at: draft)
        }
        if text != original { editor.reload(id: tab.id, markdown: text) }
        tab.autoName = false
        tab.url = url.standardizedFileURL
        tab.untitledName = nil
        tab.diskText = text
        tab.unsavedText = nil
        tab.isMissing = false
        tab.hasConflict = false
        tab.saveError = nil
        editor.moved(id: tab.id, documentURL: url)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        updateTitle()
        rewatch()
        return true
    }

    // MARK: Banner actions

    private var bannerActions: BannerActions {
        BannerActions(
            reloadFromDisk: { [weak self] id in self?.reloadFromDisk(id) },
            keepMine: { [weak self] id in
                guard let self, let tab = self.workspace.tab(id: id) else { return }
                Task { await self.save(tab) }
            },
            saveAgain: { [weak self] id in
                guard let self, let tab = self.workspace.tab(id: id) else { return }
                Task { await self.save(tab) }
            },
            close: { [weak self] id in
                Task { await self?.closeTab(id) }
            }
        )
    }

    private func reloadFromDisk(_ id: String) {
        guard let tab = workspace.tab(id: id), let url = tab.url, let text = try? TextFile.read(url).text else { return }
        tab.diskText = text
        tab.unsavedText = nil
        tab.hasConflict = false
        tab.isEditing = false
        tab.saveError = nil
        tab.isMissing = false
        editor.reload(id: id, markdown: text)
    }

    // MARK: Watching the disk

    /// Watches the folder plus the parent folders of open files outside it.
    private func rewatch() {
        // Resolved paths: FSEvents reports real paths, so a folder opened
        // through a symlink is compared resolved too (diskChanged).
        var paths = Set<String>()
        if let folder = workspace.folder { paths.insert(folder.resolvingSymlinksInPath().path) }
        for tab in workspace.tabs {
            guard let url = tab.url else { continue }
            if let folder = workspace.folder, url.isInside(folder) { continue }
            paths.insert(url.deletingLastPathComponent().resolvingSymlinksInPath().path)
        }
        watcher = FileWatcher(paths: paths.sorted()) { [weak self] changed in
            self?.diskChanged(changed)
        }
    }

    private func diskChanged(_ paths: [String]) {
        if let folder = workspace.folder?.resolvingSymlinksInPath().canonicalPath,
           paths.contains(where: { URL(fileURLWithPath: $0).canonicalPath.hasPrefix(folder + "/") && !$0.contains("/.git/") }) {
            scheduleTreeReload()
        }
        // Only look at tabs whose file (or its folder) was touched; [] means "check all".
        let changed = Set(paths.map { URL(fileURLWithPath: $0).canonicalPath })
        for tab in workspace.tabs {
            guard let url = tab.url else { continue }
            // The folder is resolved on its own, in case the file itself is gone.
            let dir = url.deletingLastPathComponent().resolvingSymlinksInPath()
            if !changed.isEmpty, !changed.contains(dir.appendingPathComponent(url.lastPathComponent).canonicalPath),
               !changed.contains(dir.canonicalPath) { continue }
            let exists = FileManager.default.fileExists(atPath: url.path)
            if !exists {
                tab.isMissing = true
                continue
            }
            tab.isMissing = false
            guard let text = try? TextFile.read(url).text, text != tab.diskText else { continue }
            if tab.unsavedText == nil, !tab.isEditing {
                tab.diskText = text
                editor.reload(id: tab.id, markdown: text)
            } else if text != tab.unsavedText {
                tab.hasConflict = true
            }
        }
    }

    private func scheduleTreeReload() {
        guard !treeReloadScheduled else { return }
        treeReloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.treeReloadScheduled = false
            self?.reloadTree()
        }
    }

    func reloadTree() {
        guard let folder = workspace.folder else { workspace.tree = []; return }
        let reloadID = UUID()
        treeReloadID = reloadID
        let showAll = Preferences.shared.showAllFiles
        Task.detached(priority: .userInitiated) {
            let tree = FileTreeLoader.load(root: folder, showAllFiles: showAll)
            await MainActor.run { [weak self] in
                guard let self, self.workspace.folder == folder, self.treeReloadID == reloadID else { return }
                // Not revealing the active file here: every autosave reloads the
                // tree, and that would re-expand a folder the user just collapsed.
                self.workspace.tree = tree
            }
        }
    }

    /// Expands the folders above the active file so it shows in the sidebar.
    private func revealActiveInTree() {
        guard let folder = workspace.folder, let url = workspace.activeTab?.url, url.isInside(folder) else { return }
        var dir = url.deletingLastPathComponent().standardizedFileURL
        while dir.path.count > folder.pathKey.count {
            workspace.expanded.insert(dir.pathKey)
            dir = dir.deletingLastPathComponent()
        }
    }

    // MARK: Project search

    private var searchTask: Task<Void, Never>?

    private func search(_ query: String) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let folder = workspace.folder else {
            workspace.searchResults = []
            workspace.isSearching = false
            return
        }
        workspace.isSearching = true
        let files = workspace.tree.flatMap(\.allFiles).filter(MarkdownFiles.isMarkdown)
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180)) // debounce typing
            guard !Task.isCancelled else { return }
            let results = await Task.detached(priority: .userInitiated) { ProjectSearch.search(q, in: files) }.value
            guard !Task.isCancelled, let self, self.workspace.folder == folder else { return }
            self.workspace.searchResults = results
            self.workspace.isSearching = false
        }
    }

    @objc func searchInFolder(_ sender: Any?) {
        guard workspace.folder != nil else { return NSSound.beep() }
        if sidebarItem.isCollapsed { setSidebarCollapsed(false) }
        workspace.sidebarMode = .search
        workspace.searchFocusRequest += 1
    }

    // MARK: Export

    private var exporter: Exporter?

    private func export(_ kind: Exporter.Kind) {
        guard let tab = workspace.activeTab, let window else { return NSSound.beep() }
        Task {
            await flushEditor()
            let exporter = self.exporter ?? Exporter()
            self.exporter = exporter
            let name = tab.url.map { $0.deletingPathExtension().lastPathComponent } ?? tab.displayName
            await exporter.run(kind, markdown: tab.unsavedText ?? tab.diskText ?? "", documentURL: tab.url,
                               suggestedName: name, in: window)
        }
    }

    @objc func exportHTML(_ sender: Any?) { export(.html) }
    @objc func exportPDF(_ sender: Any?) { export(.pdf) }
    @objc func printDocument(_ sender: Any?) { export(.print) }

    // MARK: Folder

    /// Turns an empty window into a folder window.
    func adopt(folder: URL) {
        workspace.folder = folder
        setSidebarCollapsed(false)
        NSDocumentController.shared.noteNewRecentDocumentURL(folder)
        reloadTree()
        rewatch()
        updateTitle()
    }

    private func updateTitle() {
        guard let window else { return }
        let tab = workspace.activeTab
        window.title = [tab?.displayName, workspace.folder?.lastPathComponent].compactMap { $0 }.joined(separator: " — ")
        if window.title.isEmpty { window.title = "Margin" }
        window.representedURL = tab?.url
        revealActiveInTree()
    }

    // MARK: Links, drops, images

    private func openLink(_ href: String) {
        if let url = URL(string: href), let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto", "tel", "ftp"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        // A local path, relative to the document (fragment ignored).
        var path = href.components(separatedBy: "#").first ?? href
        if path.isEmpty { return }
        if path.hasPrefix("margin-file://") { path = String(path.dropFirst("margin-file://".count)) }
        if path.hasPrefix("file://") { path = String(path.dropFirst("file://".count)) }
        path = path.removingPercentEncoding ?? path
        let base = workspace.activeTab?.url?.deletingLastPathComponent() ?? workspace.folder
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.map { $0.appendingPathComponent(path) }
        guard let url = url?.standardizedFileURL, FileManager.default.fileExists(atPath: url.path) else {
            NSSound.beep()
            return
        }
        if MarkdownFiles.isMarkdown(url) || url.isDirectoryOnDisk {
            AppDelegate.shared.open(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func handleDrop(_ urls: [URL], at point: CGPoint) -> Bool {
        let images = urls.filter(MarkdownFiles.isImage)
        if !images.isEmpty, workspace.activeTab != nil, !workspace.sourceMode {
            for url in images {
                editor.command("image", args: ["src": imageReference(for: url), "x": point.x, "y": point.y])
            }
            return true
        }
        let openable = urls.filter { MarkdownFiles.isMarkdown($0) || $0.isDirectoryOnDisk }
        guard !openable.isEmpty else { return false }
        openable.forEach { AppDelegate.shared.open($0) }
        return true
    }

    /// How a document refers to an image: relative when the document is saved.
    private func imageReference(for image: URL) -> String {
        guard let dir = workspace.activeTab?.url?.deletingLastPathComponent() else { return image.absoluteString }
        return image.markdownLinkPath(from: dir)
    }

    /// Pasting a screenshot saves it into `assets/` next to the document and
    /// returns the path to link to; nil when the pasteboard holds no image.
    private func savePastedImage(from pb: NSPasteboard) -> String? {
        guard workspace.activeTab != nil, !workspace.sourceMode else { return nil }
        let hasText = pb.availableType(from: [.string, .html, .rtf]) != nil
        guard !hasText, pb.availableType(from: [.png, .tiff]) != nil,
              let image = NSImage(pasteboard: pb),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
              let docURL = workspace.activeTab?.url else { return nil }
        let assets = docURL.deletingLastPathComponent().appendingPathComponent("assets")
        let stamp = Self.stampFormatter.string(from: Date())
        let file = TextFile.availableURL(in: assets, base: "image-\(stamp)", ext: "png")
        do {
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            try png.write(to: file)
        } catch {
            showError(error)
            return nil
        }
        return imageReference(for: file)
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    // MARK: Sidebar actions

    private var sidebarActions: SidebarActions {
        SidebarActions(
            open: { [weak self] url in self?.openFile(url) },
            newFile: { [weak self] dir in self?.createFile(in: dir) },
            newFolder: { [weak self] dir in self?.createFolder(in: dir) },
            rename: { [weak self] url in self?.rename(url) },
            trash: { [weak self] url in self?.trash(url) },
            reveal: { url in NSWorkspace.shared.activateFileViewerSelecting([url]) },
            openFolder: { AppDelegate.shared.openDocument(nil) },
            selectTab: { [weak self] id in self?.select(id) },
            goToHeading: { [weak self] index in self?.editor.goToHeading(index) },
            search: { [weak self] query in self?.search(query) },
            openMatch: { [weak self] match in
                guard let self else { return }
                self.openFile(match.url)
                let query = self.workspace.searchQuery
                // Give a newly opened tab a moment to load before searching it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.editor.reveal(query) }
            }
        )
    }

    private func createFile(in dir: URL?) {
        guard let base = dir ?? workspace.folder else { return newUntitled() }
        Task {
            guard let name = await askName(title: "New File", initial: "Untitled.md", selectStem: true) else { return }
            let fileName = name.contains(".") ? name : name + ".md"
            let url = base.appendingPathComponent(fileName)
            guard !FileManager.default.fileExists(atPath: url.path) else { return showExists(fileName) }
            do {
                try TextFile.write("", to: url)
                workspace.expanded.insert(base.pathKey)
                reloadTree()
                openFile(url)
            } catch { showError(error) }
        }
    }

    private func createFolder(in dir: URL?) {
        guard let base = dir ?? workspace.folder else { return }
        Task {
            guard let name = await askName(title: "New Folder", initial: "untitled folder", selectStem: false) else { return }
            let url = base.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: url.path) else { return showExists(name) }
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                workspace.expanded.insert(base.pathKey)
                workspace.expanded.insert(url.pathKey)
                if !Preferences.shared.showAllFiles {
                    // Empty folders are hidden from the tree; seed it with a file so it shows.
                    let file = url.appendingPathComponent("Untitled.md")
                    try TextFile.write("", to: file)
                    reloadTree()
                    openFile(file)
                } else {
                    reloadTree()
                }
            } catch { showError(error) }
        }
    }

    private func rename(_ url: URL) {
        Task {
            guard let name = await askName(title: "Rename", initial: url.lastPathComponent, selectStem: !url.isDirectoryOnDisk),
                  name != url.lastPathComponent else { return }
            let target = url.deletingLastPathComponent().appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: target.path) || target.path.lowercased() == url.path.lowercased() else {
                return showExists(name)
            }
            do {
                try FileManager.default.moveItem(at: url, to: target)
            } catch {
                return showError(error)
            }
            // Point open tabs at the new location.
            let oldPath = url.standardizedFileURL.path
            for tab in workspace.tabs {
                guard let tabURL = tab.url?.standardizedFileURL else { continue }
                if tabURL.path == oldPath {
                    tab.url = target.standardizedFileURL
                } else if tabURL.path.hasPrefix(oldPath + "/") {
                    tab.url = URL(fileURLWithPath: target.standardizedFileURL.path + tabURL.path.dropFirst(oldPath.count))
                } else { continue }
                tab.isMissing = false
                editor.moved(id: tab.id, documentURL: tab.url)
            }
            // The renamed folder, and expanded folders inside it, stay expanded.
            let oldKey = url.pathKey, newKey = target.pathKey
            workspace.expanded = Set(workspace.expanded.map {
                $0 == oldKey ? newKey : ($0.hasPrefix(oldKey + "/") ? newKey + $0.dropFirst(oldKey.count) : $0)
            })
            reloadTree()
            updateTitle()
            rewatch()
        }
    }

    private func trash(_ url: URL) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
        alert.informativeText = url.isDirectoryOnDisk ? "Everything inside the folder goes with it." : "You can restore it from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        Task {
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            // Close its tabs first, the normal way (edits saved, or asked
            // about), so what lands in the Trash is the latest text.
            for tab in workspace.tabs where tab.url.map({ $0.isInside(url) }) == true {
                await waitForSheetToClose()
                guard await closeTab(tab.id) else { return }
            }
            // An empty Untitled.md goes away with its tab.
            guard FileManager.default.fileExists(atPath: url.path) else { return reloadTree() }
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                return showError(error)
            }
            reloadTree()
        }
    }

    private func askName(title: String, initial: String, selectStem: Bool) async -> String? {
        guard let window else { return nil }
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: title == "Rename" ? "Rename" : "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        DispatchQueue.main.async {
            field.becomeFirstResponder()
            let stem = (initial as NSString).deletingPathExtension
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: selectStem ? (stem as NSString).length : (initial as NSString).length)
        }
        guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        return name
    }

    /// A sheet can't open while the previous one is still animating away.
    private func waitForSheetToClose() async {
        for _ in 0..<40 where window?.attachedSheet != nil {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private func showExists(_ name: String) {
        let alert = NSAlert()
        alert.messageText = "“\(name)” already exists."
        if let window { alert.beginSheetModal(for: window) }
    }

    // MARK: Tab bar actions

    private var tabActions: TabBarActions {
        TabBarActions(
            select: { [weak self] id in self?.select(id) },
            close: { [weak self] id in Task { await self?.closeTab(id) } },
            closeOthers: { [weak self] id in
                guard let self else { return }
                Task { for t in self.workspace.tabs where t.id != id { guard await self.closeTab(t.id) else { return } } }
            },
            closeToRight: { [weak self] id in
                guard let self, let i = self.workspace.tabs.firstIndex(where: { $0.id == id }) else { return }
                let ids = self.workspace.tabs[(i + 1)...].map(\.id)
                Task { for t in ids { guard await self.closeTab(t) else { return } } }
            },
            reveal: { [weak self] id in
                if let url = self?.workspace.tab(id: id)?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            },
            copyPath: { [weak self] id in
                guard let url = self?.workspace.tab(id: id)?.url else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path(percentEncoded: false), forType: .string)
            },
            move: { [weak self] id, index in
                guard let self, let from = self.workspace.tabs.firstIndex(where: { $0.id == id }) else { return }
                let tab = self.workspace.tabs.remove(at: from)
                self.workspace.tabs.insert(tab, at: min(index, self.workspace.tabs.count))
            },
            newTab: { [weak self] in self?.newUntitled() }
        )
    }

    private var startActions: StartActions {
        StartActions(
            newFile: { [weak self] in self?.newUntitled() },
            open: { AppDelegate.shared.openDocument(nil) },
            openRecent: { url in AppDelegate.shared.open(url) }
        )
    }

    // MARK: Menu actions (responder chain)

    @objc func newDocument(_ sender: Any?) { newUntitled() }

    @objc func saveDocument(_ sender: Any?) {
        guard let tab = workspace.activeTab else { return NSSound.beep() }
        Task { await save(tab) }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let tab = workspace.activeTab else { return NSSound.beep() }
        Task { await saveAs(tab) }
    }

    @objc func closeTab(_ sender: Any?) {
        if let id = workspace.activeTabID {
            Task { await closeTab(id) }
        } else {
            window?.performClose(sender)
        }
    }

    @objc func closeWindow(_ sender: Any?) { window?.performClose(sender) }

    @objc func revealInFinder(_ sender: Any?) {
        if let url = workspace.activeTab?.url ?? workspace.folder { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc func quickOpen(_ sender: Any?) {
        workspace.isQuickOpenVisible.toggle()
    }

    @objc func toggleSourceMode(_ sender: Any?) {
        guard workspace.activeTab != nil else { return NSSound.beep() }
        editor.setSourceMode(!workspace.sourceMode)
    }

    @objc func showFind(_ sender: Any?) { editor.find("open") }
    @objc func showFindAndReplace(_ sender: Any?) { editor.find("replace") }
    @objc func findNextMatch(_ sender: Any?) { editor.find("next") }
    @objc func findPreviousMatch(_ sender: Any?) { editor.find("previous") }

    @objc func formatCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else { return }
        if command == "image" { return insertImage(sender) }
        if command.hasPrefix("heading") {
            runCommand("heading", ["level": Int(command.dropFirst("heading".count)) ?? 0])
        } else {
            runCommand(command)
        }
    }

    @objc func insertImage(_ sender: Any?) {
        guard let window, workspace.activeTab != nil else { return NSSound.beep() }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.directoryURL = workspace.activeTab?.url?.deletingLastPathComponent() ?? workspace.folder
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            for url in panel.urls { self.runCommand("image", ["src": self.imageReference(for: url)]) }
        }
    }

    // MARK: Focus mode

    /// Whether the sidebar was showing before focus mode, to put it back.
    private var focusRestore: Bool?
    var isInFocusMode: Bool { focusRestore != nil }

    /// ⇧⌘↩: just the text — no sidebar, format bar or tabs.
    @objc func toggleFocusMode(_ sender: Any?) {
        if let sidebarWasCollapsed = focusRestore {
            focusRestore = nil
            setSidebarCollapsed(sidebarWasCollapsed)
        } else {
            focusRestore = sidebarItem.isCollapsed
            setSidebarCollapsed(true)
        }
        workspace.focusMode = isInFocusMode
        updateTitle()
        focusEditor()
    }

    @objc func toggleSidebarVisibility(_ sender: Any?) {
        setSidebarCollapsed(!sidebarItem.isCollapsed)
    }

    @objc func selectNextTab(_ sender: Any?) { cycleTab(1) }
    @objc func selectPreviousTab(_ sender: Any?) { cycleTab(-1) }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        let tabs = workspace.tabs
        guard !tabs.isEmpty else { return }
        // ⌘9 is always the last tab, as in browsers.
        let index = sender.tag == 9 ? tabs.count - 1 : sender.tag - 1
        if tabs.indices.contains(index) { select(tabs[index].id) }
    }

    private func cycleTab(_ delta: Int) {
        guard let i = workspace.activeIndex, workspace.tabs.count > 1 else { return }
        select(workspace.tabs[(i + delta + workspace.tabs.count) % workspace.tabs.count].id)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasTab = workspace.activeTab != nil
        switch item.action {
        case #selector(searchInFolder(_:)):
            return workspace.folder != nil
        case #selector(exportHTML(_:)), #selector(exportPDF(_:)), #selector(printDocument(_:)):
            return hasTab
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)), #selector(toggleSourceMode(_:)),
             #selector(showFind(_:)), #selector(showFindAndReplace(_:)), #selector(findNextMatch(_:)),
             #selector(findPreviousMatch(_:)), #selector(insertImage(_:)):
            if item.action == #selector(toggleSourceMode(_:)) { item.state = workspace.sourceMode ? .on : .off }
            return hasTab
        case #selector(formatCommand(_:)):
            let command = item.representedObject as? String ?? ""
            let state = workspace.selection
            if EditorWebView.tableCommands.contains(where: { $0.command == command }) {
                return hasTab && !workspace.sourceMode && state.has("table")
            }
            item.state = (command.hasPrefix("heading") ? Int(command.dropFirst(7)) == state.heading : state.has(command)) ? .on : .off
            return hasTab && !workspace.sourceMode
        case #selector(revealInFinder(_:)):
            return workspace.activeTab?.url != nil || workspace.folder != nil
        case #selector(toggleFocusMode(_:)):
            item.state = isInFocusMode ? .on : .off
            return true
        case #selector(toggleSidebarVisibility(_:)):
            item.title = sidebarItem.isCollapsed ? "Show Sidebar" : "Hide Sidebar"
            return true
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)):
            return workspace.tabs.count > 1
        case #selector(quickOpen(_:)):
            return workspace.folder != nil || !workspace.tabs.isEmpty
        default:
            return true
        }
    }

    // MARK: Window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeConfirmed { return true }
        Task {
            if await prepareToClose() {
                closeConfirmed = true
                sender.close()
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        removeEmptyUntitledFiles()
        watcher = nil
        if let splitObserver {
            NotificationCenter.default.removeObserver(splitObserver)
            self.splitObserver = nil
        }
        NotificationCenter.default.removeObserver(self)
        onClose?(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Catch changes made while we were in the background.
        if !workspace.tabs.isEmpty { diskChanged([]) }
    }

    // MARK: Session

    var sessionState: SessionState.Window {
        SessionState.Window(
            folder: workspace.folder?.path,
            files: workspace.tabs.compactMap { $0.url?.path },
            activeFile: workspace.activeTab?.url?.path,
            sidebarVisible: !sidebarItem.isCollapsed,
            frame: window.map { NSStringFromRect($0.frame) },
            expandedFolders: workspace.expanded.sorted()
        )
    }

    func restore(_ state: SessionState.Window) {
        workspace.expanded = Set(state.expandedFolders)
        for path in state.files { openFile(URL(fileURLWithPath: path), activate: false) }
        if let active = state.activeFile.flatMap({ workspace.tab(for: URL(fileURLWithPath: $0)) }) ?? workspace.tabs.first {
            select(active.id)
        }
        setSidebarCollapsed(!state.sidebarVisible, animated: false)
        if let frame = state.frame { window?.setFrame(NSRectFromString(frame), display: false) }
    }
}
