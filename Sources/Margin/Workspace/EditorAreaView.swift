import MarginCore
import SwiftUI

struct BannerActions {
    var reloadFromDisk: (String) -> Void
    var keepMine: (String) -> Void
    var saveAgain: (String) -> Void
    var close: (String) -> Void
}

struct StartActions {
    var newFile: () -> Void
    var open: () -> Void
    var openRecent: (URL) -> Void
}

/// What the header and format bar ask the window to do.
struct ChromeActions {
    var toggleSidebar: () -> Void
    var toggleSource: () -> Void
    var run: (_ command: String, _ args: [String: Any]) -> Void
    var pickImage: () -> Void
}

/// Right side of the window: a header row with the tabs, the format bar,
/// then the editor.
struct EditorAreaView: View {
    let workspace: Workspace
    let editorView: AnyView
    let tabActions: TabBarActions
    let bannerActions: BannerActions
    let startActions: StartActions
    let chromeActions: ChromeActions
    let openFile: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .zIndex(2)
            if workspace.activeTab != nil, !workspace.focusMode {
                FormatBar(selection: workspace.selection, enabled: !workspace.sourceMode,
                          run: chromeActions.run, pickImage: chromeActions.pickImage)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .background(WindowDragArea())
                    .zIndex(1)
            }
            if !workspace.focusMode, !workspace.tabs.isEmpty {
                Rectangle().fill(Chrome.hairline).frame(height: 1)
            }
            if let tab = workspace.activeTab {
                BannerView(tab: tab, actions: bannerActions)
            }
            ZStack(alignment: .top) {
                editorView
                    .opacity(workspace.tabs.isEmpty ? 0 : 1)
                if workspace.tabs.isEmpty {
                    StartView(workspace: workspace, actions: startActions)
                }
                if workspace.isQuickOpenVisible {
                    QuickOpenView(workspace: workspace, open: openFile)
                        .padding(.top, 12)
                }
            }
        }
        .background(Chrome.canvas)
        .ignoresSafeArea()
    }

    /// Sidebar toggle (after the traffic lights when the sidebar is hidden),
    /// tabs, word count, source.
    private var header: some View {
        HStack(spacing: 6) {
            if workspace.sidebarCollapsed {
                Color.clear.frame(width: Chrome.trafficLightsWidth - 6, height: 1)
            }
            ChromeButton(symbol: "sidebar.left", help: workspace.sidebarCollapsed ? "Show Sidebar  ⌃⌘S" : "Hide Sidebar  ⌃⌘S",
                         action: chromeActions.toggleSidebar)
            if !workspace.focusMode, !workspace.tabs.isEmpty {
                TabBarView(workspace: workspace, actions: tabActions)
            } else {
                Spacer()
            }
            if workspace.activeTab != nil, !workspace.focusMode {
                if workspace.wordCount > 0 {
                    Text("\(workspace.wordCount) \(workspace.wordCount == 1 ? "word" : "words")")
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .help("Words in this document")
                }
                ChromeButton(symbol: "number", help: workspace.sourceMode ? "Show Formatted  ⇧⌘M" : "Show Markdown Source  ⇧⌘M",
                             active: workspace.sourceMode, action: chromeActions.toggleSource)
            }
        }
        .padding(.leading, workspace.sidebarCollapsed ? 0 : 10)
        .padding(.trailing, 12)
        .frame(height: Chrome.headerHeight)
        .background(WindowDragArea())
    }
}

/// Problems with the active file: changed on disk, deleted, or failed to save.
private struct BannerView: View {
    let tab: Tab
    let actions: BannerActions

    var body: some View {
        if tab.hasConflict {
            bar(icon: "exclamationmark.arrow.triangle.2.circlepath",
                text: "“\(tab.displayName)” changed on disk while you were editing.") {
                Button("Use Disk Version") { actions.reloadFromDisk(tab.id) }
                Button("Keep Mine") { actions.keepMine(tab.id) }.keyboardShortcut(.defaultAction)
            }
        } else if tab.isMissing {
            bar(icon: "trash", text: "“\(tab.displayName)” was deleted or moved.") {
                Button("Close Tab") { actions.close(tab.id) }
                Button("Save Again") { actions.saveAgain(tab.id) }
            }
        } else if let error = tab.saveError {
            bar(icon: "exclamationmark.triangle", text: "Couldn’t save: \(error)") {
                Button("Try Again") { actions.saveAgain(tab.id) }
            }
        }
    }

    private func bar(icon: String, text: String, @ViewBuilder buttons: () -> some View) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.orange)
            Text(text).lineLimit(2)
            Spacer()
            buttons().controlSize(.small)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Shown when a window has no tabs.
private struct StartView: View {
    let workspace: Workspace
    let actions: StartActions

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 40)
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .padding(.bottom, 4)
                Text(workspace.folder?.lastPathComponent ?? "Margin")
                    .font(.title2.weight(.semibold))
                Text(workspace.folder == nil ? "Open a folder or a Markdown file, or just start a new one." : "Pick a file in the sidebar, press ⌘P, or start a new one.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("New File", action: actions.newFile)
                    .keyboardShortcut("n", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                Button("Open…", action: actions.open)
            }
            .controlSize(.large)

            let recents = NSDocumentController.shared.recentDocumentURLs.prefix(6)
            if workspace.folder == nil, !recents.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)
                    ForEach(Array(recents), id: \.self) { url in
                        RecentRow(url: url) { actions.openRecent(url) }
                    }
                }
                .font(.callout)
                .padding(.top, 8)
            }
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct RecentRow: View {
    let url: URL
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: url.hasDirectoryPath || url.isDirectoryOnDisk ? "folder" : "doc.text")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(url.lastPathComponent)
                Text(url.deletingLastPathComponent().path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .frame(maxWidth: 380, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
