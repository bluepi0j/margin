import AppKit
import MarginCore
import Sparkle
import SwiftUI
import UniformTypeIdentifiers

/// App lifecycle: routes "open" requests to windows, restores the last
/// session, and coordinates quitting.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    private(set) var controllers: [WorkspaceWindowController] = []
    /// Updates (Sparkle): checks the feed in Info.plist once a day, then
    /// downloads, installs and relaunches when the user agrees.
    let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var settingsWindow: NSWindow?
    private var launched = false
    /// URLs handed to us before launch finished (Finder double-click).
    private var pendingOpens: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        _ = NSDocumentController.shared // enables the recent-documents list
        NSApp.mainMenu = MainMenu.build(recentDelegate: self)
        Preferences.shared.applyAppearance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        // ⌃Tab / ⌃⇧Tab switch tabs. WKWebView swallows these before the menu sees them.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.keyCode == 48, mods.contains(.control), !mods.contains(.command),
                  let controller = self?.keyController else { return event }
            if mods.contains(.shift) { controller.selectPreviousTab(nil) } else { controller.selectNextTab(nil) }
            return nil
        }
        // A new system accent color should reach the open editor pages too.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleColorPreferencesChangedNotification"),
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                NotificationCenter.default.post(name: Preferences.didChange, object: Preferences.shared)
            }
        }
        // Bring back the last session first, so a file opened from Finder lands
        // in its project window rather than a fresh one.
        let restored = restoreSession()
        if !pendingOpens.isEmpty {
            pendingOpens.forEach { open($0) }
            pendingOpens = []
        } else if !restored {
            newWindow(nil)
        }
        NSApp.activate()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else {
            pendingOpens += urls
            return
        }
        urls.forEach { open($0) }
    }

    // MARK: Opening

    var keyController: WorkspaceWindowController? {
        controllers.first { $0.window?.isKeyWindow == true }
            ?? controllers.first { $0.window?.isMainWindow == true }
    }

    /// Opens a file or folder in the right window (see OpenRouter).
    func open(_ url: URL) {
        let url = url.standardizedFileURL
        let isDirectory = url.isDirectoryOnDisk
        guard FileManager.default.fileExists(atPath: url.path) else { return NSSound.beep() }
        // Front-most first, so "the window in front" means what the user sees.
        let ordered = NSApp.orderedWindows.compactMap { w in controllers.first { $0.window === w } }
            + controllers.filter { c in !NSApp.orderedWindows.contains { $0 === c.window } }
        let infos = ordered.map {
            OpenRouter.WindowInfo(id: ObjectIdentifier($0).hashValue, folder: $0.workspace.folder,
                                  openFiles: $0.workspace.tabs.compactMap(\.url), tabCount: $0.workspace.tabs.count)
        }
        let key = keyController.map { ObjectIdentifier($0).hashValue }
        let find = { (id: Int) in ordered.first { ObjectIdentifier($0).hashValue == id } }

        switch OpenRouter.route(url, isDirectory: isDirectory, windows: infos, keyWindow: key) {
        case .focusTab(let id, let file):
            guard let c = find(id) else { return }
            c.showWindow(nil)
            c.openFile(file)
        case .openTab(let id, let file):
            guard let c = find(id) else { return }
            c.showWindow(nil)
            c.openFile(file)
        case .focusWindow(let id):
            find(id)?.showWindow(nil)
        case .adoptFolder(let id, let folder):
            guard let c = find(id) else { return }
            c.adopt(folder: folder)
            c.showWindow(nil)
        case .newWindow(let folder, let file):
            let c = makeController(folder: folder)
            if let file { c.openFile(file) }
            c.showWindow(nil)
        }
    }

    @discardableResult
    func makeController(folder: URL?) -> WorkspaceWindowController {
        let c = WorkspaceWindowController(folder: folder)
        c.onClose = { [weak self] closed in self?.controllers.removeAll { $0 === closed } }
        // Cascade from the window in front.
        if let front = keyController?.window ?? controllers.last?.window {
            let origin = front.frame.origin
            c.window?.setFrameOrigin(NSPoint(x: origin.x + 26, y: origin.y - 26))
        }
        controllers.append(c)
        return c
    }

    // MARK: Menu actions

    @objc func newWindow(_ sender: Any?) {
        makeController(folder: nil).showWindow(nil)
    }

    /// File > New when no window is open.
    @objc func newDocument(_ sender: Any?) {
        let c = makeController(folder: nil)
        c.showWindow(nil)
        c.newUntitled()
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose a Markdown file or a folder"
        panel.prompt = "Open"
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            panel.urls.forEach { self?.open($0) }
        }
        if let window = keyController?.window { panel.beginSheetModal(for: window, completionHandler: handler) }
        else { panel.begin(completionHandler: handler) }
    }

    @objc func openRecentItem(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { open(url) }
    }

    @objc func clearRecent(_ sender: Any?) {
        NSDocumentController.shared.clearRecentDocuments(sender)
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(prefs: Preferences.shared))
            host.sizingOptions = .preferredContentSize // the window follows each pane's height
            let window = NSWindow(contentViewController: host)
            window.title = "Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func zoomIn(_ sender: Any?) { Preferences.shared.zoom(by: 1) }
    @objc func zoomOut(_ sender: Any?) { Preferences.shared.zoom(by: -1) }
    @objc func actualSize(_ sender: Any?) { Preferences.shared.fontSize = 16 }

    @objc func showHelp(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://commonmark.org/help/")!)
    }

    // MARK: Open Recent menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        for url in urls {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecentItem(_:)), keyEquivalent: "")
            item.representedObject = url
            item.target = self
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            item.toolTip = url.path(percentEncoded: false)
            menu.addItem(item)
        }
        if !urls.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: "Clear Menu", action: urls.isEmpty ? nil : #selector(clearRecent(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    // MARK: Session & quitting

    private static let sessionKey = "MarginSession"

    private func restoreSession() -> Bool {
        guard Preferences.shared.restoreSession,
              let state = SessionState.decode(UserDefaults.standard.data(forKey: Self.sessionKey))?.pruned(),
              !state.windows.isEmpty else { return false }
        for w in state.windows {
            let c = makeController(folder: w.folder.map { URL(fileURLWithPath: $0) })
            c.restore(w)
            c.showWindow(nil)
        }
        return true
    }

    private func saveSession() {
        // Back to front, so restoring brings the front window up last.
        // Windows not on screen (miniaturized) aren't in orderedWindows but still count.
        let onScreen = NSApp.orderedWindows.compactMap { w in controllers.first { $0.window === w } }
        let ordered = (onScreen + controllers.filter { c in !onScreen.contains { $0 === c } }).reversed()
        let state = SessionState(windows: ordered.map(\.sessionState).filter { $0.folder != nil || !$0.files.isEmpty })
        UserDefaults.standard.set(state.encoded(), forKey: Self.sessionKey)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            for c in controllers {
                guard await c.prepareToClose(quitting: true) else {
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            // Every window agreed: empty new files can go now, and closing may
            // have renamed new files or saved drafts under a new path.
            for c in controllers { c.removeEmptyUntitledFiles() }
            saveSession()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
