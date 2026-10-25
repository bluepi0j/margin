import MarginCore
import SwiftUI

/// ⌘P: fuzzy-find a file in the project and open it as a tab.
struct QuickOpenView: View {
    @Bindable var workspace: Workspace
    let open: (URL) -> Void

    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private var results: [(path: String, url: URL)] {
        let files = workspace.projectFiles
        let byPath = Dictionary(files.map { ($0.path, $0.url) }, uniquingKeysWith: { a, _ in a })
        return FuzzyMatch.rank(query, paths: files.map(\.path), limit: 40).compactMap { p in byPath[p].map { (p, $0) } }
    }

    var body: some View {
        let results = self.results
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Go to file…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { choose(results) }
                    .onKeyPress(.downArrow) { move(1, results.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, results.count); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            if !results.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.path) { i, item in
                                row(item.path, selected: i == selected)
                                    .id(i)
                                    .onTapGesture {
                                        selected = i
                                        choose(results)
                                    }
                            }
                        }
                        .padding(5)
                    }
                    .frame(height: min(320, CGFloat(results.count) * 29 + 10))
                    .onChange(of: selected) { _, i in proxy.scrollTo(i) }
                }
            } else if !query.isEmpty {
                Divider()
                Text("No matching files").foregroundStyle(.secondary).padding(14)
            }
        }
        .frame(width: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in selected = 0 }
        .onChange(of: focused) { _, f in if !f { dismiss() } }
    }

    private func row(_ path: String, selected: Bool) -> some View {
        let name = (path as NSString).lastPathComponent
        let dir = (path as NSString).deletingLastPathComponent
        return HStack(spacing: 8) {
            Image(systemName: "doc.text").foregroundStyle(selected ? .white : .secondary)
            Text(name).foregroundStyle(selected ? .white : .primary)
            Text(dir).foregroundStyle(selected ? .white.opacity(0.75) : .secondary).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : .clear))
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int, _ count: Int) {
        guard count > 0 else { return }
        selected = (selected + delta + count) % count
    }

    private func choose(_ results: [(path: String, url: URL)]) {
        guard results.indices.contains(selected) else { return }
        let url = results[selected].url
        dismiss()
        open(url)
    }

    private func dismiss() {
        workspace.isQuickOpenVisible = false
    }
}
