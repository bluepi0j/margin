import MarginCore
import SwiftUI
import UniformTypeIdentifiers

/// What the tab bar asks its window to do.
struct TabBarActions {
    var select: (String) -> Void
    var close: (String) -> Void
    var closeOthers: (String) -> Void
    var closeToRight: (String) -> Void
    var reveal: (String) -> Void
    var copyPath: (String) -> Void
    var move: (_ id: String, _ toIndex: Int) -> Void
    var newTab: () -> Void
}

/// VS Code-style tab strip, in the window's header row.
struct TabBarView: View {
    let workspace: Workspace
    let actions: TabBarActions

    var body: some View {
        let titles = TabTitles.titles(for: workspace.tabs.map { $0.isDraft ? nil : $0.url },
                                      untitledNames: workspace.tabs.map { $0.isDraft ? $0.displayName : $0.untitledName })
        HStack(spacing: 2) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(Array(workspace.tabs.enumerated()), id: \.element.id) { index, tab in
                            TabItemView(
                                tab: tab,
                                title: Self.trimmed(titles[index].title),
                                hint: titles[index].hint,
                                isActive: tab.id == workspace.activeTabID,
                                actions: actions
                            )
                            .id(tab.id)
                            .onDrag { NSItemProvider(object: tab.id as NSString) }
                            .onDrop(of: [UTType.text], delegate: TabDropDelegate(targetIndex: index, move: actions.move))
                        }
                    }
                }
                .onChange(of: workspace.activeTabID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            ChromeButton(symbol: "plus", help: "New File  ⌘N", size: 26, action: actions.newTab)
            Spacer(minLength: 0)
        }
    }
}

extension TabBarView {
    /// Markdown is the default, so its extension is noise — the sidebar strips
    /// the same set (MarginCore/MarkdownFiles.swift), and tabs should match.
    static func trimmed(_ title: String) -> String {
        for ext in MarkdownFiles.extensions.sorted(by: { $0.count > $1.count }) {
            let dotted = "." + ext
            if title.lowercased().hasSuffix(dotted) && title.count > dotted.count {
                return String(title.dropLast(dotted.count))
            }
        }
        return title
    }
}

private struct TabItemView: View {
    let tab: Tab
    let title: String
    let hint: String?
    let isActive: Bool
    let actions: TabBarActions
    @State private var hovering = false
    @State private var hoveringClose = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: isActive ? .medium : .regular))
                .foregroundStyle(tab.isMissing ? .secondary : (isActive ? .primary : .secondary))
                .strikethrough(tab.isMissing)
                .lineLimit(1)
            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            closeButton
        }
        .padding(.leading, 11)
        .padding(.trailing, 5)
        .frame(height: 30)
        .frame(minWidth: 84, maxWidth: 220)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? Chrome.selected : (hovering ? Chrome.hover : .clear))
        )
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { actions.select(tab.id) }
        .help(tab.url?.path(percentEncoded: false) ?? tab.displayName)
        .contextMenu {
            Button("Close Tab") { actions.close(tab.id) }
            Button("Close Other Tabs") { actions.closeOthers(tab.id) }
            Button("Close Tabs to the Right") { actions.closeToRight(tab.id) }
            if tab.url != nil {
                Divider()
                Button("Reveal in Finder") { actions.reveal(tab.id) }
                Button("Copy Path") { actions.copyPath(tab.id) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(title)
        .accessibilityAction { actions.select(tab.id) }
        .accessibilityAction(named: "Close") { actions.close(tab.id) }
    }

    @ViewBuilder private var closeButton: some View {
        let showDot = tab.isDirty && !hovering
        Button { actions.close(tab.id) } label: {
            ZStack {
                if showDot {
                    Circle().fill(Color.secondary).frame(width: 7, height: 7)
                } else {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(hoveringClose ? .primary : .secondary)
                        .opacity(hovering || isActive ? 1 : 0)
                }
            }
            .frame(width: 20, height: 20)
            .background(Circle().fill(hoveringClose ? Color.primary.opacity(0.1) : .clear))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hoveringClose = $0 }
        .help(tab.isDirty ? "Unsaved changes — Close" : "Close (⌘W)")
        .accessibilityLabel("Close \(tab.displayName)")
    }
}

private struct TabDropDelegate: DropDelegate {
    let targetIndex: Int
    let move: (String, Int) -> Void

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.text]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { item, _ in
            guard let id = item as? String else { return }
            DispatchQueue.main.async { move(id, targetIndex) }
        }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}
