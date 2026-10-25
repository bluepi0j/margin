import AppKit
import MarginCore
import MarkdownEngine
import MarkdownEngineCodeBlocks
import MarkdownEngineLatex
import SwiftUI

/// The native editor: swift-markdown-engine's TextKit 2 view, which styles
/// Markdown live and hides the syntax except where the caret is. The text is
/// the file, byte for byte, so nothing is ever re-formatted on save.
@MainActor
final class NativeDocumentEditor: DocumentEditor {
    var onEvent: ((EditorEvent) -> Void)?
    var savePastedImage: ((NSPasteboard) -> String?)?

    fileprivate let model = NativeEditorModel()
    fileprivate let images = LocalImageProvider()
    private var texts: [String: String] = [:]
    private var urls: [String: URL] = [:]
    private var pending: Set<String> = []
    private var saveTimer: Timer?
    private var infoTimer: Timer?
    private var lastSelection = EditorSelection()
    private weak var cachedTextView: NSTextView?
    private var selectionObserver: NSObjectProtocol?
    private var scrollObserver: NSObjectProtocol?
    private var appearance = Preferences.shared.appearance
    private var keyMonitor: Any?

    init() {
        applySettings()
        DispatchQueue.main.async { [weak self] in self?.onEvent?(.ready) }
        // Tab / ⇧Tab in a table: move between cells instead of typing a tab.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 48, event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  let self, self.moveInTable(forward: !event.modifierFlags.contains(.shift), window: event.window) else { return event }
            return nil
        }
    }

    deinit {
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    var view: AnyView {
        AnyView(NativeEditorView(model: model, editor: self))
    }

    var focusView: NSView? { textView }

    // MARK: Documents

    func open(id: String, markdown: String, documentURL: URL?, activate: Bool) {
        texts[id] = markdown
        urls[id] = documentURL
        if activate || model.documentId == nil { self.activate(id: id) }
    }

    func activate(id: String) {
        guard let text = texts[id] else { return }
        if let current = model.documentId, pending.contains(current) { postContent(current) }
        images.base = urls[id]?.deletingLastPathComponent()
        model.documentId = id
        model.text = text
        scheduleInfo()
    }

    func close(id: String) {
        if pending.contains(id) { postContent(id) }
        texts[id] = nil
        urls[id] = nil
        if model.documentId == id {
            model.documentId = nil
            model.text = ""
            scheduleInfo()
        }
    }

    func reload(id: String, markdown: String) {
        texts[id] = markdown
        pending.remove(id)
        guard model.documentId == id else { return }
        let tv = textView
        let old = tv?.string ?? model.text
        let caret = tv.map { MarkdownEditing.mapLocation($0.selectedRange().location, from: old, to: markdown) }
        let origin = tv?.enclosingScrollView?.contentView.bounds.origin
        model.text = markdown
        // Put the caret (moved along with the edit) and the scroll position back
        // once the engine has re-laid out.
        DispatchQueue.main.async {
            guard let tv, let caret else { return }
            let length = (tv.string as NSString).length
            tv.setSelectedRange(NSRange(location: min(caret, length), length: 0))
            if let origin { tv.enclosingScrollView?.contentView.scroll(to: origin) }
        }
        scheduleInfo()
    }

    func moved(id: String, documentURL: URL?) {
        urls[id] = documentURL
        if model.documentId == id { images.base = documentURL?.deletingLastPathComponent() }
    }

    /// From the text binding: the user typed.
    fileprivate func textDidChange(_ text: String) {
        guard let id = model.documentId, texts[id] != text else { return }
        texts[id] = text
        if !pending.contains(id) {
            pending.insert(id)
            onEvent?(.edited(id: id))
        }
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.flushNow() }
        }
        scheduleInfo()
    }

    private func postContent(_ id: String) {
        pending.remove(id)
        if let text = texts[id] { onEvent?(.content(id: id, markdown: text)) }
    }

    @discardableResult
    private func flushNow() -> [String: String] {
        saveTimer?.invalidate()
        var out: [String: String] = [:]
        for id in pending {
            if let text = texts[id] { out[id] = text }
            postContent(id)
        }
        return out
    }

    func flush() async -> [String: String] { flushNow() }

    // MARK: Text view access

    /// The engine's NSTextView (found once in the window, then cached).
    var textView: NSTextView? {
        if let cachedTextView, cachedTextView.window != nil { return cachedTextView }
        guard let root = model.hostView?.window?.contentView ?? model.hostView else { return nil }
        let found = Self.findTextView(in: root)
        cachedTextView = found
        if let found {
            found.usesFindBar = true
            found.isIncrementalSearchingEnabled = true
            if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
            selectionObserver = NotificationCenter.default.addObserver(
                forName: NSTextView.didChangeSelectionNotification, object: found, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.selectionDidChange() } }
            if let clip = found.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
                scrollObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.trackRail(); self?.updateBlockChip() } }
            }
        }
        return found
    }

    private static func findTextView(in view: NSView) -> NSTextView? {
        // The engine's view, not a text field's shared field editor.
        if let tv = view as? NSTextView, !tv.isFieldEditor, tv.isEditable { return tv }
        for sub in view.subviews { if let tv = findTextView(in: sub) { return tv } }
        return nil
    }

    fileprivate func viewAppeared() {
        _ = textView
        scheduleInfo()
    }

    private func selectionDidChange() {
        guard let tv = textView, model.documentId != nil else { return }
        let state = MarkdownEditing.state(tv.string, caret: tv.selectedRange().location)
        var sel = EditorSelection()
        sel.flags = state.flags
        sel.heading = state.heading
        sel.sourceMode = model.rawSource
        if MarkdownTable.at(tv.selectedRange().location, in: tv.string) != nil { sel.flags.insert("table") }
        if sel != lastSelection {
            lastSelection = sel
            onEvent?(.selection(sel))
        }
        updateBlockChip()
    }

    // MARK: Code block and table labels

    /// Puts a small label at the top right of the code block (its language)
    /// or table (its row and column commands) the caret is in, or removes it.
    private func updateBlockChip() {
        guard let tv = textView, !model.rawSource, let scroll = tv.enclosingScrollView else { return setChip(nil) }
        let caret = tv.selectedRange().location
        let kind: NativeEditorModel.BlockChip.Kind
        let start: Int
        if let fence = MarkdownEditing.codeFence(containing: caret, in: tv.string) {
            kind = .code(language: fence.language)
            start = fence.openingLine.location
        } else if let table = MarkdownTable.at(caret, in: tv.string) {
            kind = .table
            start = table.range.location
        } else {
            return setChip(nil)
        }
        guard let y = yOffset(of: start, in: tv) else { return setChip(nil) }
        let width = tv.textContainer?.size.width ?? tv.bounds.width
        var point = tv.convert(NSPoint(x: tv.textContainerOrigin.x + width - 16, y: y + 6), to: scroll)
        if !scroll.isFlipped { point.y = scroll.bounds.height - point.y }
        setChip(NativeEditorModel.BlockChip(kind: kind, trailing: point.x, top: point.y))
    }

    private func setChip(_ chip: NativeEditorModel.BlockChip?) {
        if model.blockChip != chip { model.blockChip = chip }
    }

    /// Replaces text the way typing does (undoable, restyled), then selects `selection`.
    private func replace(_ edit: MarkdownEditing.Edit, selection: NSRange) {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
        tv.insertText(edit.text, replacementRange: edit.range)
        let length = (tv.string as NSString).length
        let location = min(selection.location, length)
        tv.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        updateBlockChip()
    }

    fileprivate func editTable(_ operation: MarkdownTable.Operation) {
        guard let tv = textView, let table = MarkdownTable.at(tv.selectedRange().location, in: tv.string) else { return }
        let edit = table.applying(operation).edit
        replace(edit, selection: edit.selection)
    }

    /// Tab in a table: next cell (a new row after the last). False when the
    /// caret isn't in a table of this editor, so the key goes on as usual.
    private func moveInTable(forward: Bool, window: NSWindow?) -> Bool {
        guard let tv = textView, !model.rawSource, tv.window === window, window?.firstResponder === tv,
              tv.selectedRange().length == 0,
              let table = MarkdownTable.at(tv.selectedRange().location, in: tv.string) else { return false }
        let edit = table.movingToCell(forward: forward).edit
        replace(edit, selection: edit.selection)
        return true
    }

    fileprivate func setCodeLanguage(_ language: String) {
        guard let tv = textView, let fence = MarkdownEditing.codeFence(containing: tv.selectedRange().location, in: tv.string) else { return }
        let edit = MarkdownEditing.setLanguage(language, of: fence)
        let caret = tv.selectedRange().location
        let delta = (edit.text as NSString).length - edit.range.length
        // Leave the caret in the code where it was.
        replace(edit, selection: NSRange(location: caret >= NSMaxRange(edit.range) ? caret + delta : caret, length: 0))
    }

    // MARK: Commands

    private func apply(_ edit: MarkdownEditing.Edit) {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
        // Same path as typing, so the engine restyles and records undo.
        tv.insertText(edit.text, replacementRange: edit.range)
        let length = (tv.string as NSString).length
        tv.setSelectedRange(NSRange(location: min(edit.selection.location, length),
                                    length: min(edit.selection.length, max(0, length - edit.selection.location))))
        tv.scrollRangeToVisible(tv.selectedRange())
    }

    func command(_ name: String, args: [String: Any]) {
        guard let tv = textView, model.documentId != nil else { return NSSound.beep() }
        let text = tv.string
        let sel = tv.selectedRange()
        if let marker = MarkdownEditing.inlineMarkers[name] {
            return apply(MarkdownEditing.toggleInline(text, sel, marker: marker))
        }
        switch name {
        case "link": apply(MarkdownEditing.link(text, sel))
        case "inlineMath": apply(MarkdownEditing.toggleInline(text, sel, marker: "$"))
        case "heading":
            let level = args["level"] as? Int ?? 0
            apply(MarkdownEditing.setLineKind(text, sel, level == 0 ? .paragraph : .heading(level)))
        case "paragraph", "clearFormatting": apply(MarkdownEditing.setLineKind(text, sel, .paragraph))
        case "bulletList": apply(MarkdownEditing.setLineKind(text, sel, .bullet))
        case "orderedList": apply(MarkdownEditing.setLineKind(text, sel, .ordered))
        case "taskList": apply(MarkdownEditing.setLineKind(text, sel, .task))
        case "blockquote": apply(MarkdownEditing.setLineKind(text, sel, .quote))
        case "image":
            let src = args["src"] as? String ?? ""
            let alt = ((src as NSString).lastPathComponent.removingPercentEncoding ?? "") as NSString
            apply(MarkdownEditing.insertBlock(text, sel, "![\(alt.deletingPathExtension)](\(src))", caretOffset: 0))
        case "addRowBefore": editTable(.addRowAbove)
        case "addRowAfter": editTable(.addRowBelow)
        case "addColumnBefore": editTable(.addColumnLeft)
        case "addColumnAfter": editTable(.addColumnRight)
        case "deleteRow": editTable(.deleteRow)
        case "deleteColumn": editTable(.deleteColumn)
        case "deleteTable":
            if let table = MarkdownTable.at(sel.location, in: text) {
                replace(MarkdownEditing.Edit(range: table.range, text: "", selection: NSRange(location: table.range.location, length: 0)),
                        selection: NSRange(location: table.range.location, length: 0))
            }
        case "undo": tv.undoManager?.undo()
        case "redo": tv.undoManager?.redo()
        default:
            let selected = (text as NSString).substring(with: sel)
            if let (block, caret) = MarkdownEditing.blockSnippet(name, selection: selected) {
                apply(MarkdownEditing.insertBlock(text, sel, block, caretOffset: caret))
            } else {
                NSSound.beep()
            }
        }
    }

    func setSourceMode(_ on: Bool) {
        model.rawSource = on
        lastSelection.sourceMode = on
        onEvent?(.selection(lastSelection))
    }

    func find(_ mode: String) {
        guard let tv = textView else { return }
        let action: NSTextFinder.Action = switch mode {
        case "replace": .showReplaceInterface
        case "next": .nextMatch
        case "previous": .previousMatch
        default: .showFindInterface
        }
        let item = NSMenuItem()
        item.tag = action.rawValue
        tv.window?.makeFirstResponder(tv)
        tv.performTextFinderAction(item)
    }

    func applySettings() {
        let prefs = Preferences.shared
        model.fontSize = prefs.fontSize
        model.readingWidth = prefs.contentWidth
        model.fontName = prefs.fontStyle.fontName
        model.showsRail = prefs.showOutlineRail
        // The highlighter only hears about the system's appearance; tell it
        // when Margin's own setting flips light/dark so code is re-colored.
        if prefs.appearance != appearance {
            appearance = prefs.appearance
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .markdownEngineHighlighterDidChangeAppearance, object: nil)
            }
        }
    }

    func focus() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }

    func goToHeading(_ index: Int) {
        guard let tv = textView else { return }
        let headings = MarkdownEditing.headings(tv.string)
        guard headings.indices.contains(index) else { return }
        let range = NSRange(location: headings[index].location, length: 0)
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(range)
        tv.scrollRangeToVisible(range)
    }

    func reveal(_ text: String) {
        guard let tv = textView else { return }
        let range = (tv.string as NSString).range(of: text, options: [.caseInsensitive, .diacriticInsensitive])
        guard range.location != NSNotFound else { return }
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(range)
        tv.scrollRangeToVisible(range)
        tv.showFindIndicator(for: range)
    }

    // MARK: Outline and word count

    private func scheduleInfo() {
        infoTimer?.invalidate()
        infoTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.postInfo() }
        }
    }

    private func postInfo() {
        guard model.documentId != nil else { return onEvent?(.outline([], words: 0)) ?? () }
        let text = model.text
        let items = MarkdownEditing.headings(text).enumerated().map { OutlineItem(id: $0.offset, level: $0.element.level, text: $0.element.text) }
        let words = MarkdownEditing.wordCount(text)
        model.wordCount = words
        onEvent?(.outline(items, words: words))
        updateRail(text)
        updateBlockChip()
    }

    // MARK: Outline rail

    private func updateRail(_ text: String) {
        let ns = text as NSString
        let all = MarkdownEditing.headings(text).filter { $0.level <= 3 }
        let rail = all.enumerated().map { i, h -> RailHeading in
            // The section's text: from the line after the heading to the next one.
            let lineEnd = NSMaxRange(ns.lineRange(for: NSRange(location: h.location, length: 0)))
            let end = i + 1 < all.count ? all[i + 1].location : ns.length
            let body = lineEnd < end ? ns.substring(with: NSRange(location: lineEnd, length: min(end - lineEnd, 400))) : ""
            let preview = body
                .replacingOccurrences(of: #"[#>*_`~=|\[\]-]"#, with: "", options: .regularExpression)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return RailHeading(level: h.level, title: h.text, preview: String(preview.prefix(180)), location: h.location,
                               percent: ns.length == 0 ? 0 : h.location * 100 / ns.length)
        }
        if model.railHeadings != rail { model.railHeadings = rail }
        trackRail()
    }

    /// Which heading the top of the window is under.
    private func trackRail() {
        guard !model.railHeadings.isEmpty, let tv = textView, let top = characterIndex(atY: tv.visibleRect.minY + 80, in: tv) else { return }
        let current = model.railHeadings.lastIndex { $0.location <= top } ?? 0
        if model.railCurrent != current { model.railCurrent = current }
    }

    fileprivate func jumpToRailHeading(_ index: Int, animated: Bool) {
        guard let tv = textView, model.railHeadings.indices.contains(index),
              let y = yOffset(of: model.railHeadings[index].location, in: tv),
              let scroll = tv.enclosingScrollView else { return }
        let clip = scroll.contentView
        let maxY = max(0, tv.frame.height - clip.bounds.height)
        let target = NSPoint(x: clip.bounds.origin.x, y: min(max(0, y - 24), maxY))
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(target)
            } completionHandler: { scroll.reflectScrolledClipView(clip) }
        } else {
            clip.setBoundsOrigin(target)
            scroll.reflectScrolledClipView(clip)
        }
    }

    /// Top of the line holding `location`, in the text view's coordinates.
    private func yOffset(of location: Int, in tv: NSTextView) -> CGFloat? {
        if let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager,
           let loc = tcm.location(tcm.documentRange.location, offsetBy: location),
           let upTo = NSTextRange(location: tcm.documentRange.location, end: loc) {
            tlm.ensureLayout(for: upTo)
            guard let fragment = tlm.textLayoutFragment(for: loc) else { return nil }
            return fragment.layoutFragmentFrame.minY + tv.textContainerOrigin.y
        }
        guard let lm = tv.layoutManager else { return nil }
        let glyph = lm.glyphIndexForCharacter(at: location)
        return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + tv.textContainerOrigin.y
    }

    private func characterIndex(atY y: CGFloat, in tv: NSTextView) -> Int? {
        let point = CGPoint(x: 0, y: y - tv.textContainerOrigin.y)
        if let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager {
            guard let fragment = tlm.textLayoutFragment(for: point) else { return nil }
            return tcm.offset(from: tcm.documentRange.location, to: fragment.rangeInElement.location)
        }
        guard let lm = tv.layoutManager, let container = tv.textContainer else { return nil }
        return lm.characterIndexForGlyph(at: lm.glyphIndex(for: point, in: container))
    }
}

// MARK: - SwiftUI

@MainActor @Observable
final class NativeEditorModel {
    var text = ""
    var documentId: String?
    var fontSize: Double = 16
    var fontName = NSFont.systemFont(ofSize: 16).fontName
    var readingWidth: Double = 760
    var rawSource = false
    var wordCount = 0
    var showsRail = true
    var railHeadings: [RailHeading] = []
    var railCurrent = 0
    /// The label at the top right of the code block or table at the caret,
    /// in the editor view's coordinates.
    var blockChip: BlockChip?
    struct BlockChip: Equatable {
        enum Kind: Equatable { case code(language: String), table }
        let kind: Kind
        let trailing: CGFloat
        let top: CGFloat
    }
    /// The hosting view, used to find the engine's NSTextView.
    @ObservationIgnored weak var hostView: NSView?
}

private struct NativeEditorView: View {
    @Bindable var model: NativeEditorModel
    let editor: NativeDocumentEditor

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let id = model.documentId {
                NativeTextViewWrapper(
                    text: Binding(get: { model.text }, set: { new in
                        model.text = new
                        editor.textDidChange(new)
                    }),
                    configuration: configuration,
                    fontName: model.fontName,
                    fontSize: model.fontSize,
                    documentId: id,
                    onPasteImage: { pb in editor.savePastedImage?(pb).map { "![](\($0))" } },
                    placeholder: NSAttributedString(string: "Start writing…", attributes: [
                        .foregroundColor: NSColor.placeholderTextColor,
                        .font: NSFont.systemFont(ofSize: model.fontSize),
                    ])
                )
                .background(HostViewReader { model.hostView = $0; editor.viewAppeared() })
            }
        }
        .overlay(alignment: .topLeading) {
            if let chip = model.blockChip {
                Group {
                    switch chip.kind {
                    case .code(let language): CodeLanguageMenu(language: language) { editor.setCodeLanguage($0) }
                    case .table: TableMenu { editor.editTable($0) }
                    }
                }
                .frame(width: max(0, chip.trailing), alignment: .trailing)
                .offset(y: chip.top)
            }
        }
        .overlay(alignment: .leading) {
            GeometryReader { geo in
                // Only where the margin beside the text has room for it.
                let gutter = (geo.size.width - min(model.readingWidth, geo.size.width)) / 2
                if model.showsRail, !model.rawSource, model.railHeadings.count >= 3, gutter >= 64 {
                    OutlineRailView(headings: model.railHeadings, current: model.railCurrent) { index, animated in
                        editor.jumpToRailHeading(index, animated: animated)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var configuration: MarkdownEditorConfiguration {
        var c = MarkdownEditorConfiguration(
            services: MarkdownEditorServices(images: editor.images, syntaxHighlighter: Self.highlighter, latex: Self.latex,
                                             codeBlockRenderer: Self.mermaid),
            safeAreaInsets: SafeAreaInsets(top: 28, bottom: 40),
            readingWidth: model.readingWidth,
            rawSourceMode: model.rawSource,
            extensions: [HighlightExtension(), StrikethroughExtension()]
        )
        c.headings.fontMultipliers = [2.0, 1.5, 1.25, 1.07, 1.0, 0.92]
        return c
    }

    // Shared: highlight.js and the math fonts load once per app. Colors are
    // CodePalette's, the same as the web editor's.
    private static let highlighter = HighlightJSBridge(
        lightTheme: CodeHighlightTheme(CodePalette.light), darkTheme: CodeHighlightTheme(CodePalette.dark),
        lightBackground: NSColor(hex: CodePalette.light.background), darkBackground: NSColor(hex: CodePalette.dark.background)
    )
    private static let latex = SwiftMathBridge()
    private static let mermaid = MermaidBlockRenderer()
}

/// "⊞ ⌄" at the top right of a table: add / delete rows and columns.
private struct TableMenu: View {
    let run: (MarkdownTable.Operation) -> Void

    var body: some View {
        Menu {
            Button("Add Row Above") { run(.addRowAbove) }
            Button("Add Row Below") { run(.addRowBelow) }
            Divider()
            Button("Add Column Left") { run(.addColumnLeft) }
            Button("Add Column Right") { run(.addColumnRight) }
            Divider()
            Button("Delete Row") { run(.deleteRow) }
            Button("Delete Column") { run(.deleteColumn) }
            Divider()
            Button("Align Columns") { run(.tidy) }
        } label: {
            ChipLabel(text: "table", symbol: "tablecells")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Rows and columns — Tab moves to the next cell")
    }
}

/// The small rounded label both block menus use.
private struct ChipLabel: View {
    let text: String
    var symbol: String?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10)) }
            Text(text)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(hovering ? 0.09 : 0.05)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// "python ⌄" at the top right of a code block: pick the block's language.
private struct CodeLanguageMenu: View {
    let language: String
    let choose: (String) -> Void

    private static let languages: [(String, String)] = [
        ("", "Plain Text"), ("bash", "Shell"), ("c", "C"), ("cpp", "C++"), ("csharp", "C#"), ("css", "CSS"),
        ("go", "Go"), ("html", "HTML"), ("java", "Java"), ("javascript", "JavaScript"), ("json", "JSON"),
        ("kotlin", "Kotlin"), ("markdown", "Markdown"), ("mermaid", "Mermaid"), ("php", "PHP"), ("python", "Python"),
        ("ruby", "Ruby"), ("rust", "Rust"), ("sql", "SQL"), ("swift", "Swift"), ("typescript", "TypeScript"), ("yaml", "YAML"),
    ]

    var body: some View {
        Menu {
            ForEach(Self.languages, id: \.0) { id, name in
                Toggle(name, isOn: Binding(get: { language.lowercased() == id }, set: { _ in choose(id) }))
            }
        } label: {
            ChipLabel(text: language.isEmpty ? "plain text" : language)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Code language")
    }
}

/// Reports the NSView it is attached to (to locate the engine's text view).
private struct HostViewReader: NSViewRepresentable {
    let onAttach: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let s = v.superview?.superview { onAttach(s) } }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Loads `![alt](path)` images relative to the document's folder.
final class LocalImageProvider: EmbeddedImageProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _base: URL?
    private var cache: [String: NSImage] = [:]

    var base: URL? {
        get { lock.withLock { _base } }
        set { lock.withLock { _base = newValue } }
    }

    func image(for reference: EmbeddedImageRequest) -> NSImage? {
        let name = reference.name.trimmingCharacters(in: .whitespaces)
        let (dir, cached) = lock.withLock { (_base, cache[(_base?.path ?? "") + "|" + name]) }
        if let cached { return cached }
        let url: URL?
        if name.hasPrefix("http://") || name.hasPrefix("https://") {
            url = nil // no network loads on the main thread
        } else if name.hasPrefix("file://") {
            url = URL(string: name)
        } else {
            let path = name.removingPercentEncoding ?? name
            url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : dir?.appendingPathComponent(path)
        }
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        lock.withLock { cache[(dir?.path ?? "") + "|" + name] = image }
        return image
    }

    func fingerprint() -> AnyHashable { base?.path ?? "" }
}

private extension CodeHighlightTheme {
    init(_ colors: CodePalette.Colors) {
        var byScope: [String: NSColor] = [:]
        for (role, scopes) in CodePalette.scopes {
            for scope in scopes { byScope[scope] = NSColor(hex: colors.roles[role]!) }
        }
        // The bridge marks calls (`nums.sort()`) itself; highlight.js in the
        // web editor doesn't, so they stay plain there — and here.
        byScope["title.function.invoke"] = NSColor(hex: colors.text)
        self.init(foreground: NSColor(hex: colors.text), background: NSColor(hex: colors.background), colors: byScope)
    }
}

private extension NSColor {
    convenience init(hex: Int) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
