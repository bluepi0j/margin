import MarginCore
import SwiftUI

struct SidebarActions {
    var open: (URL) -> Void
    var newFile: (_ inFolder: URL?) -> Void
    var newFolder: (_ inFolder: URL?) -> Void
    var rename: (URL) -> Void
    var trash: (URL) -> Void
    var reveal: (URL) -> Void
    var openFolder: () -> Void
    var selectTab: (String) -> Void
    var goToHeading: (Int) -> Void
    var search: (String) -> Void
    var openMatch: (ProjectSearch.Match) -> Void
}

/// Left column: the traffic-light row with the Files / Outline / Search
/// switcher, then the chosen view's list.
struct SidebarView: View {
    @Bindable var workspace: Workspace
    let actions: SidebarActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The traffic-light row doubles as the view switcher.
            HStack(spacing: 2) {
                Spacer()
                ChromeButton(symbol: "folder", help: "Files", active: workspace.sidebarMode == .files, size: 26) {
                    workspace.sidebarMode = .files
                }
                ChromeButton(symbol: "list.bullet.indent", help: "Outline", active: workspace.sidebarMode == .outline, size: 26) {
                    workspace.sidebarMode = .outline
                }
                if workspace.folder != nil {
                    ChromeButton(symbol: "magnifyingglass", help: "Search in Folder  ⇧⌘F", active: workspace.sidebarMode == .search, size: 26) {
                        workspace.sidebarMode = .search
                        workspace.searchFocusRequest += 1
                    }
                }
            }
            .padding(.leading, Chrome.trafficLightsWidth)
            .padding(.trailing, 10)
            .frame(height: Chrome.headerHeight)
            .background(WindowDragArea())
            .zIndex(1)

            switch workspace.sidebarMode {
            case .files:
                if let folder = workspace.folder { ProjectList(folder: folder, workspace: workspace, actions: actions) }
                else { OpenFilesList(workspace: workspace, actions: actions) }
            case .outline:
                OutlineList(workspace: workspace, actions: actions)
            case .search:
                SearchList(workspace: workspace, actions: actions)
            }
        }
        .frame(minWidth: 200, maxHeight: .infinity, alignment: .top)
        .background(Chrome.sidebar)
        .ignoresSafeArea()
    }
}

// MARK: - Header pieces

/// Small uppercase heading over a list, with an optional trailing control.
private struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
            trailing
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .frame(height: 24)
        .padding(.top, 4)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

// MARK: - Files

private struct ProjectList: View {
    let folder: URL
    @Bindable var workspace: Workspace
    let actions: SidebarActions

    var body: some View {
        SectionHeader(title: folder.lastPathComponent) {
            ChromeButton(symbol: "plus", help: "New File  ⌘N", size: 22) { actions.newFile(nil) }
        }
        .help(folder.path(percentEncoded: false))
        .contextMenu {
            Button("New File") { actions.newFile(nil) }
            Button("New Folder") { actions.newFolder(nil) }
            Divider()
            Button("Reveal in Finder") { actions.reveal(folder) }
        }
        ScrollView {
            LazyVStack(spacing: 1) {
                if workspace.tree.isEmpty {
                    Text("No Markdown files yet")
                        .foregroundStyle(.tertiary)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 8)
                }
                ForEach(visibleRows, id: \.node.id) { row in
                    FileRow(node: row.node, depth: row.depth, workspace: workspace, actions: actions)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .contextMenu {
            Button("New File") { actions.newFile(nil) }
            Button("New Folder") { actions.newFolder(nil) }
        }
    }

    /// The tree flattened to what's expanded, so the list stays lazy.
    private var visibleRows: [(node: FileNode, depth: Int)] {
        var rows: [(node: FileNode, depth: Int)] = []
        func walk(_ nodes: [FileNode], _ depth: Int) {
            for node in nodes {
                rows.append((node, depth))
                if node.isDirectory, workspace.expanded.contains(node.url.pathKey) { walk(node.children ?? [], depth + 1) }
            }
        }
        walk(workspace.tree, 0)
        return rows
    }
}

private struct FileRow: View {
    let node: FileNode
    let depth: Int
    @Bindable var workspace: Workspace
    let actions: SidebarActions
    @State private var hovering = false

    var body: some View {
        let isOpen = workspace.expanded.contains(node.url.pathKey)
        let isSelected = !node.isDirectory && workspace.activeTab?.url?.pathKey == node.url.pathKey
        let markdown = MarkdownFiles.isMarkdown(node.url)
        Button(action: activate) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 12)
                    .opacity(node.isDirectory ? 1 : 0)
                if node.isDirectory {
                    Image(systemName: "folder")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                } else {
                    Image(systemName: markdown ? "doc.text" : "doc")
                        .font(.system(size: 13))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .frame(width: 18)
                }
                Text(markdown ? node.url.deletingPathExtension().lastPathComponent : node.name)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if node.isDirectory {
                    let count = node.allFiles.count
                    if count > 0 {
                        Text("\(count)").font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.leading, 4 + CGFloat(depth) * 14)
            .padding(.trailing, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Chrome.selected : (hovering ? Chrome.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(node.name)
        .contextMenu { if node.isDirectory { menu(folder: node.url) } else { menu(file: node.url) } }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func activate() {
        if node.isDirectory {
            withAnimation(.easeOut(duration: 0.12)) {
                if workspace.expanded.remove(node.url.pathKey) == nil { workspace.expanded.insert(node.url.pathKey) }
            }
        } else {
            actions.open(node.url)
        }
    }

    @ViewBuilder private func menu(folder: URL) -> some View {
        Button("New File") { actions.newFile(folder) }
        Button("New Folder") { actions.newFolder(folder) }
        Divider()
        Button("Rename…") { actions.rename(folder) }
        Button("Reveal in Finder") { actions.reveal(folder) }
        Divider()
        Button("Move to Trash") { actions.trash(folder) }
    }

    @ViewBuilder private func menu(file: URL) -> some View {
        Button("Open") { actions.open(file) }
        Divider()
        Button("Rename…") { actions.rename(file) }
        Button("Reveal in Finder") { actions.reveal(file) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(file.path(percentEncoded: false), forType: .string)
        }
        Divider()
        Button("Move to Trash") { actions.trash(file) }
    }
}

private struct OpenFilesList: View {
    @Bindable var workspace: Workspace
    let actions: SidebarActions

    var body: some View {
        SectionHeader(title: "Open Files")
        ScrollView {
            VStack(spacing: 1) {
                ForEach(workspace.tabs) { tab in
                    PlainRow(title: tab.isDraft ? tab.displayName : (tab.url?.deletingPathExtension().lastPathComponent ?? tab.displayName),
                             symbol: "doc.text", selected: tab.id == workspace.activeTabID) { actions.selectTab(tab.id) }
                        .help(tab.url?.path(percentEncoded: false) ?? "")
                }
                PlainRow(title: "Open Folder…", symbol: "folder.badge.plus", selected: false, secondary: true, action: actions.openFolder)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 10)
        }
    }
}

/// A one-line clickable row in the sidebar's style.
private struct PlainRow: View {
    let title: String
    var symbol: String?
    let selected: Bool
    var secondary = false
    var indent: CGFloat = 0
    var weight: Font.Weight = .regular
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18)
                }
                Text(title)
                    .font(.system(size: 13, weight: selected ? .medium : weight))
                    .foregroundStyle(secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 8 + indent)
            .padding(.trailing, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Chrome.selected : (hovering ? Chrome.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Outline

private struct OutlineList: View {
    @Bindable var workspace: Workspace
    let actions: SidebarActions

    var body: some View {
        let minLevel = workspace.outline.map(\.level).min() ?? 1
        SectionHeader(title: workspace.activeTab?.displayName ?? "Outline")
        ScrollView {
            VStack(spacing: 1) {
                if workspace.outline.isEmpty {
                    Text(workspace.activeTab == nil ? "No document open" : "No headings")
                        .foregroundStyle(.tertiary)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 8)
                }
                ForEach(workspace.outline) { item in
                    PlainRow(title: item.text.isEmpty ? "Untitled" : item.text, selected: false,
                             secondary: item.level != minLevel, indent: CGFloat(item.level - minLevel) * 14,
                             weight: item.level == minLevel ? .medium : .regular) { actions.goToHeading(item.id) }
                }
            }
            .padding(.horizontal, 10)
        }
    }
}

// MARK: - Search

private struct SearchList: View {
    @Bindable var workspace: Workspace
    let actions: SidebarActions
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search in folder", text: $workspace.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($focused)
                    .onSubmit { actions.search(workspace.searchQuery) }
                if workspace.isSearching { ProgressView().controlSize(.mini) }
                else if !workspace.searchQuery.isEmpty {
                    Button { workspace.searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Chrome.hairline, lineWidth: 1))
            .padding(.horizontal, 10)
            .padding(.top, 16)
            .padding(.bottom, 4)

            let groups = Dictionary(grouping: workspace.searchResults, by: \.url)
            let files = workspace.searchResults.map(\.url).reduce(into: [URL]()) { if !$0.contains($1) { $0.append($1) } }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if !workspace.searchQuery.isEmpty, !workspace.isSearching, workspace.searchResults.isEmpty {
                        Text("No results").foregroundStyle(.tertiary).font(.callout).padding(.leading, 8).padding(.top, 8)
                    }
                    ForEach(files, id: \.self) { url in
                        Text(url.deletingPathExtension().lastPathComponent.uppercased())
                            .font(.system(size: 10.5, weight: .semibold))
                            .kerning(0.6)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 8)
                            .padding(.top, 12)
                            .padding(.bottom, 2)
                        ForEach(groups[url] ?? []) { match in
                            MatchRow(text: highlighted(match)) { actions.openMatch(match) }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onChange(of: workspace.searchFocusRequest) { _, _ in DispatchQueue.main.async { focused = true } }
        .onChange(of: workspace.searchQuery) { _, query in actions.search(query) }
    }

    private func highlighted(_ match: ProjectSearch.Match) -> AttributedString {
        var s = AttributedString(match.snippet)
        s.foregroundColor = .secondary
        if let r = Range(match.range, in: s) {
            s[r].foregroundColor = .primary
            s[r].font = .system(size: 12, weight: .semibold)
        }
        return s
    }
}

private struct MatchRow: View {
    let text: AttributedString
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Chrome.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
