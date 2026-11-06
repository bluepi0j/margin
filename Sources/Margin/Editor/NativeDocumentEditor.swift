import AppKit
import MarginCore
import MarkdownEngine
import MarkdownEngineCodeBlocks
import MarkdownEngineLatex
import SwiftUI

/// The native editor: swift-markdown-engine's TextKit 2 view, which styles
/// Markdown live and hides the syntax except where the caret is. The text is
/// the Markdown as typed, so saving does not reformat its syntax.
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
    private var findBarContainer: NativeFindBarContainer?
    private var findMatchRanges: [NSRange] = []
    private var findMatchQuery = ""
    private var findCurrentIndex: Int?
    private var lastPostedFindIndex: Int?
    private var lastPostedFindRanges: [NSRange] = []
    private var railIsVisible = false
    private var findNeedsRefreshAfterDocumentChange = false
    private var findQueryWorkItem: DispatchWorkItem?
    private let findNotifications = NativeFindNotifications()
    private var selectionObserver: NSObjectProtocol?
    private var scrollObserver: NSObjectProtocol?
    private var appearance = Preferences.shared.appearance
    private var keyMonitor: Any?
    private struct BlockChipContext {
        let storageLength: Int
        let caret: Int
        let codeFence: MarkdownEditing.CodeFence?
        let table: MarkdownTable?
    }
    private var blockChipContext: BlockChipContext?
    /// The code blocks of the text view's current text, rebuilt on the first
    /// caret move after its characters change rather than scanned per move.
    private var fencedBlocks: (text: String, blocks: [MarkdownEditing.FencedBlock])?

    init() {
        applySettings()
        DispatchQueue.main.async { [weak self] in self?.onEvent?(.ready) }
        // NSTextView consumes ⌘F/⌘G before the menu bar gets a chance to route
        // them to Margin, which would bring back AppKit's dimmed find overlay.
        // Route those commands to our host-owned bar while this editor's window
        // is active. Keep the table Tab handling in the same monitor.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.model.hostView?.window else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53, self.findBarContainer?.isFindBarVisible == true {
                self.closeFind()
                return nil
            }
            if modifiers.contains(.command), !modifiers.contains(.control),
               let key = event.charactersIgnoringModifiers?.lowercased() {
                if key == "f", !modifiers.contains(.shift) {
                    self.find(modifiers.contains(.option) ? "replace" : "open")
                    return nil
                }
                if key == "g", !modifiers.contains(.option) {
                    self.find(modifiers.contains(.shift) ? "previous" : "next")
                    return nil
                }
            }
            guard event.keyCode == 48, modifiers.intersection([.command, .option, .control]).isEmpty,
                  self.moveInTable(forward: !modifiers.contains(.shift), window: event.window) else { return event }
            return nil
        }
    }

    deinit {
        findQueryWorkItem?.cancel()
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
        lastPostedFindIndex = nil
        lastPostedFindRanges = []
        findNeedsRefreshAfterDocumentChange = true
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
        findNeedsRefreshAfterDocumentChange = true
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
        findNeedsRefreshAfterDocumentChange = true
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
            found.usesFindBar = false
            let scrollView = found.enclosingScrollView
            if let scrollView {
                let container = NativeFindBarContainer(scrollView: scrollView)
                container.onLayoutChange = { [weak self] in
                    self?.scheduleFindBarLayoutUpdate()
                }
                container.onQueryChange = { [weak self] query in
                    self?.scheduleFindQuery(query)
                }
                container.onNext = { [weak self] in self?.stepFind(1) }
                container.onPrevious = { [weak self] in self?.stepFind(-1) }
                container.onClose = { [weak self] in self?.closeFind() }
                container.onReplace = { [weak self] replacement in
                    self?.replaceCurrentFindMatch(with: replacement)
                }
                container.onReplaceAll = { [weak self] replacement in
                    self?.replaceAllFindMatches(with: replacement)
                }
                scrollView.addSubview(container, positioned: .above, relativeTo: scrollView.contentView)
                findBarContainer = container
            }
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
        let text = tv.string
        let caret = tv.selectedRange().location
        let state = MarkdownEditing.state(text, caret: caret, blocks: blocks(of: text))
        let table = state.codeFence == nil
            ? MarkdownTable.at(caret, in: text, codeFenceAlreadyChecked: true)
            : nil
        var sel = EditorSelection()
        sel.flags = state.flags
        sel.heading = state.heading
        sel.sourceMode = model.rawSource
        if table != nil { sel.flags.insert("table") }
        if sel != lastSelection {
            lastSelection = sel
            onEvent?(.selection(sel))
        }
        refreshFindHighlightSelection()
        let context = BlockChipContext(
            storageLength: tv.textStorage?.length ?? (text as NSString).length,
            caret: caret,
            codeFence: state.codeFence,
            table: table
        )
        blockChipContext = context
        updateBlockChip(context)
    }

    // MARK: Code block and table labels

    /// Puts a small label at the top right of the code block (its language)
    /// or table (its row and column commands) the caret is in, or removes it.
    private func updateBlockChip() {
        guard let tv = textView, model.documentId != nil else { return setChip(nil) }
        let caret = tv.selectedRange().location
        let storageLength = tv.textStorage?.length ?? 0
        if let cached = blockChipContext,
           cached.storageLength == storageLength,
           cached.caret == caret {
            updateBlockChip(cached)
            return
        }
        let text = tv.string
        let fence = MarkdownEditing.codeFence(containing: caret, in: blocks(of: text))
        let table = fence == nil
            ? MarkdownTable.at(caret, in: text, codeFenceAlreadyChecked: true)
            : nil
        let context = BlockChipContext(
            storageLength: storageLength,
            caret: caret,
            codeFence: fence,
            table: table
        )
        blockChipContext = context
        updateBlockChip(context)
    }

    /// The code blocks of `text`. Comparing with the cached text is cheap when
    /// it is unchanged (the same storage) and only rescans after an edit.
    private func blocks(of text: String) -> [MarkdownEditing.FencedBlock] {
        if let cached = fencedBlocks, cached.text == text { return cached.blocks }
        let blocks = MarkdownEditing.fencedBlocks(in: text)
        fencedBlocks = (text, blocks)
        return blocks
    }

    private func updateBlockChip(_ context: BlockChipContext) {
        guard let tv = textView, !model.rawSource, let scroll = tv.enclosingScrollView else {
            return setChip(nil)
        }
        let kind: NativeEditorModel.BlockChip.Kind
        let start: Int
        if let fence = context.codeFence {
            kind = .code(language: fence.language)
            start = fence.openingLine.location
        } else if let table = context.table {
            kind = .table
            start = table.range.location
        } else {
            return setChip(nil)
        }
        // Scrolling calls this repeatedly while the caret can remain in a code
        // block or table far from the viewport. Asking TextKit for that anchor's
        // Y can settle the entire document prefix, which is especially costly
        // on large notes. The chip only has a visible position when its anchor
        // has already entered TextKit's viewport pass; otherwise it belongs off
        // screen and can stay hidden until a later scroll creates its fragment.
        guard let y = laidOutYOffset(of: start, in: tv) else { return setChip(nil) }
        let width = tv.textContainer?.size.width ?? tv.bounds.width
        var point = tv.convert(NSPoint(x: tv.textContainerOrigin.x + width - 16, y: y + 6), to: scroll)
        if !scroll.isFlipped { point.y = scroll.bounds.height - point.y }
        setChip(NativeEditorModel.BlockChip(kind: kind, trailing: point.x, top: point.y))
    }

    private func updateFindBarLayout() {
        guard let container = findBarContainer else { return }
        // Derive this from the current editor state instead of relying on the
        // SwiftUI geometry callback. During document switches and window
        // resizes that callback can miss the rail's final visible state, which
        // leaves the find field on top of the outline ticks.
        let viewportWidth = container.scrollView?.contentView.bounds.width ?? 0
        container.leadingInset = NativeFindBarLayout.leadingInset(
            showsRail: model.showsRail,
            rawSourceMode: model.rawSource,
            headingCount: model.railHeadings.count,
            viewportWidth: viewportWidth,
            readingWidth: CGFloat(model.readingWidth),
            railIsVisible: railIsVisible
        )
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
        guard container.isFindBarVisible else {
            clearFindHighlights()
            return
        }
    }

    fileprivate func scheduleFindBarLayoutUpdate() {
        DispatchQueue.main.async { [weak self] in
            self?.updateFindBarLayout()
        }
    }

    fileprivate func railVisibilityDidChange(_ visible: Bool) {
        railIsVisible = visible
        updateFindBarLayout()
    }

    private func refreshFindAfterDocumentChange() {
        guard let bar = findBarContainer, bar.isFindBarVisible else { return }
        // Rebuilding Markdown styling replaces the storage attributes, including
        // the find backgrounds. Force a fresh post even when the ranges did not
        // change, otherwise postFindHighlights sees identical cached ranges and
        // leaves every match visually unhighlighted.
        lastPostedFindIndex = nil
        lastPostedFindRanges = []
        // Repaint only: the edit happened where the caret is, and jumping to
        // the current match would pull the view away from the text being typed.
        setFindQuery(bar.query, preferredIndex: nil, reveal: false)
    }

    private static func findRanges(in text: NSString, query: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        var ranges: [NSRange] = []
        var searchStart = 0
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        while searchStart < text.length {
            let scope = NSRange(location: searchStart, length: text.length - searchStart)
            let found = text.range(of: query, options: options, range: scope)
            if found.location == NSNotFound { break }
            ranges.append(found)
            searchStart = NSMaxRange(found) + (found.length == 0 ? 1 : 0)
        }
        return ranges
    }

    private func scheduleFindQuery(_ query: String) {
        findQueryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.findQueryWorkItem = nil
            self.setFindQuery(query, preferredIndex: nil)
        }
        findQueryWorkItem = work
        // A common prefix such as "A" can match thousands of paragraphs in a
        // large note. Re-highlighting every intermediate prefix makes the main
        // thread look hung, so style only the query left after typing settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func setFindQuery(_ query: String, preferredIndex: Int?, afterReplacementAt: Int? = nil,
                              reveal: Bool = true) {
        findQueryWorkItem?.cancel()
        findQueryWorkItem = nil
        let previousIndex = query == findMatchQuery ? findCurrentIndex : nil
        findMatchQuery = query
        guard let tv = textView, let bar = findBarContainer else { return }
        let text = tv.string as NSString
        findMatchRanges = Self.findRanges(in: text, query: query)

        if findMatchRanges.isEmpty {
            findCurrentIndex = nil
            bar.setResultCount(nil)
            clearFindHighlights()
            return
        }

        let caret = tv.selectedRange().location
        let nearest = findMatchRanges.indices.min {
            let lhs = abs(findMatchRanges[$0].location - caret)
            let rhs = abs(findMatchRanges[$1].location - caret)
            return lhs < rhs
        } ?? 0
        let requested = afterReplacementAt.map { end in
            findMatchRanges.firstIndex { $0.location >= end } ?? -1
        } ?? preferredIndex ?? previousIndex ?? nearest
        // -1 leaves the remaining matches highlighted without selecting a
        // replacement again. Next/Previous explicitly resumes navigation.
        findCurrentIndex = min(max(requested, -1), findMatchRanges.count - 1)
        bar.setResultCount(findMatchRanges.count > 0 ? (findCurrentIndex! + 1, findMatchRanges.count) : nil)
        postFindHighlights(reveal: reveal)
    }

    private func postFindHighlights(reveal: Bool = true) {
        guard findBarContainer?.isFindBarVisible == true,
              let index = findCurrentIndex,
              !findMatchRanges.isEmpty else {
            clearFindHighlights()
            return
        }
        if index == lastPostedFindIndex, findMatchRanges == lastPostedFindRanges { return }
        lastPostedFindIndex = index
        lastPostedFindRanges = findMatchRanges
        NotificationCenter.default.post(
            name: findNotifications.scrollToRange,
            object: nil,
            userInfo: ["allRanges": findMatchRanges, "currentIndex": index, "reveal": reveal]
        )
    }

    private func refreshFindHighlightSelection() {
        guard findBarContainer?.isFindBarVisible == true, let tv = textView,
              !findMatchRanges.isEmpty else {
            clearFindHighlights()
            return
        }
        let selected = tv.selectedRange()
        let currentIndex = findMatchRanges.firstIndex(of: selected) ?? findMatchRanges.indices.min {
            let lhs = findMatchRanges[$0]
            let rhs = findMatchRanges[$1]
            let lhsDistance = abs(lhs.location + lhs.length / 2 - selected.location)
            let rhsDistance = abs(rhs.location + rhs.length / 2 - selected.location)
            return lhsDistance < rhsDistance
        } ?? 0
        findCurrentIndex = currentIndex
        findBarContainer?.setResultCount((currentIndex + 1, findMatchRanges.count))
        // The caret moved on its own (a click, typing): follow it, don't scroll.
        postFindHighlights(reveal: false)
    }

    private func clearFindHighlights() {
        guard lastPostedFindIndex != nil else { return }
        lastPostedFindIndex = nil
        lastPostedFindRanges = []
        NotificationCenter.default.post(name: findNotifications.clearHighlights, object: nil)
    }

    private func stepFind(_ delta: Int) {
        guard let bar = findBarContainer else { return }
        if !bar.isFindBarVisible {
            showFind(replace: false)
            return
        }
        if bar.query != findMatchQuery {
            setFindQuery(bar.query, preferredIndex: nil)
            return
        }
        if findMatchRanges.isEmpty {
            setFindQuery(bar.query, preferredIndex: nil)
        }
        guard !findMatchRanges.isEmpty else { return }
        let current = findCurrentIndex ?? (delta > 0 ? -1 : 0)
        findCurrentIndex = current < 0
            ? (delta > 0 ? 0 : findMatchRanges.count - 1)
            : (current + delta + findMatchRanges.count) % findMatchRanges.count
        bar.setResultCount((findCurrentIndex! + 1, findMatchRanges.count))
        postFindHighlights()
    }

    private func showFind(replace: Bool) {
        guard let tv = textView, let bar = findBarContainer else { return }
        if !replace,
           let selected = selectedFindText(in: tv) {
            bar.query = selected
        }
        bar.setReplaceVisible(replace || bar.showsReplace)
        bar.isFindBarVisible = true
        updateFindBarLayout()
        setFindQuery(bar.query, preferredIndex: nil)
        bar.focusSearch()
    }

    private func closeFind() {
        guard let bar = findBarContainer else { return }
        findQueryWorkItem?.cancel()
        findQueryWorkItem = nil
        bar.isFindBarVisible = false
        findCurrentIndex = nil
        findMatchRanges = []
        findMatchQuery = ""
        bar.setResultCount(nil)
        clearFindHighlights()
        scheduleFindBarLayoutUpdate()
        textView?.window?.makeFirstResponder(textView)
    }

    private func selectedFindText(in textView: NSTextView) -> String? {
        let selection = textView.selectedRange()
        guard selection.location != NSNotFound, selection.length > 0,
              NSMaxRange(selection) <= (textView.string as NSString).length else { return nil }
        let selected = (textView.string as NSString).substring(with: selection)
        guard !selected.contains("\n"), !selected.contains("\r") else { return nil }
        return selected
    }

    private func replaceCurrentFindMatch(with replacement: String) {
        guard let tv = textView, let index = findCurrentIndex,
              findMatchRanges.indices.contains(index) else { return }
        guard findBarContainer?.query == findMatchQuery else {
            setFindQuery(findBarContainer?.query ?? "", preferredIndex: nil)
            return
        }
        let target = findMatchRanges[index]
        guard NSMaxRange(target) <= (tv.string as NSString).length else { return }
        tv.breakUndoCoalescing()
        guard tv.shouldChangeText(in: target, replacementString: replacement) else { return }
        tv.replaceCharacters(in: target, with: replacement)
        tv.didChangeText()
        tv.undoManager?.setActionName("Replace")
        tv.breakUndoCoalescing()

        findNeedsRefreshAfterDocumentChange = false
        setFindQuery(findBarContainer?.query ?? "", preferredIndex: nil,
                     afterReplacementAt: target.location + (replacement as NSString).length)
        findBarContainer?.focusReplace()
    }

    private func replaceAllFindMatches(with replacement: String) {
        guard let tv = textView, !findMatchRanges.isEmpty else { return }
        guard findBarContainer?.query == findMatchQuery else {
            setFindQuery(findBarContainer?.query ?? "", preferredIndex: nil)
            return
        }
        let ranges = findMatchRanges.reversed().map { NSValue(range: $0) }
        let replacements = Array(repeating: replacement, count: findMatchRanges.count)
        tv.breakUndoCoalescing()
        guard tv.shouldChangeText(inRanges: ranges, replacementStrings: replacements) else { return }
        tv.textStorage?.beginEditing()
        for range in findMatchRanges.reversed() {
            tv.textStorage?.replaceCharacters(in: range, with: replacement)
        }
        tv.textStorage?.endEditing()
        tv.didChangeText()
        tv.undoManager?.setActionName("Replace All")
        tv.breakUndoCoalescing()

        findNeedsRefreshAfterDocumentChange = false
        setFindQuery(findBarContainer?.query ?? "", preferredIndex: 0)
        findBarContainer?.focusReplace()
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
        findNeedsRefreshAfterDocumentChange = true
        scheduleInfo()
        scheduleFindBarLayoutUpdate()
        lastSelection.sourceMode = on
        onEvent?(.selection(lastSelection))
    }

    func find(_ mode: String) {
        guard model.documentId != nil, textView != nil, findBarContainer != nil else {
            NSSound.beep()
            return
        }
        switch mode {
        case "replace":
            showFind(replace: true)
        case "next":
            stepFind(1)
        case "previous":
            stepFind(-1)
        default:
            showFind(replace: false)
        }
    }

    fileprivate var findBus: MarkdownEditorBus {
        MarkdownEditorBus(
            findScrollToRange: findNotifications.scrollToRange,
            findClearHighlights: findNotifications.clearHighlights
        )
    }

    func applySettings() {
        let prefs = Preferences.shared
        model.fontSize = prefs.fontSize
        model.readingWidth = prefs.contentWidth
        model.fontName = prefs.fontStyle.fontName
        model.showsRail = prefs.showOutlineRail
        scheduleFindBarLayoutUpdate()
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
        let headings = MarkdownEditing.headings(text)
        let items = headings.enumerated().map { OutlineItem(id: $0.offset, level: $0.element.level, text: $0.element.text) }
        let words = MarkdownEditing.wordCount(text)
        model.wordCount = words
        onEvent?(.outline(items, words: words))
        updateRail(text, headings: headings)
        updateBlockChip()
        if findNeedsRefreshAfterDocumentChange {
            findNeedsRefreshAfterDocumentChange = false
            refreshFindAfterDocumentChange()
        }
    }

    // MARK: Outline rail

    private func updateRail(_ text: String, headings: [MarkdownEditing.Heading]) {
        let ns = text as NSString
        let all = headings.filter { $0.level <= 3 }
        let rail = all.enumerated().map { i, h -> RailHeading in
            // The section's text: from the line after the heading to the next one.
            let lineEnd = NSMaxRange(ns.lineRange(for: NSRange(location: h.location, length: 0)))
            let end = i + 1 < all.count ? all[i + 1].location : ns.length
            let preview = lineEnd < end ? Self.railPreview(ns, in: NSRange(location: lineEnd, length: min(end - lineEnd, 400))) : ""
            return RailHeading(level: h.level, title: h.text, preview: preview, location: h.location,
                               percent: ns.length == 0 ? 0 : h.location * 100 / ns.length)
        }
        if model.railHeadings != rail {
            model.railHeadings = rail
            scheduleFindBarLayoutUpdate()
        }
        trackRail()
    }

    /// A section's opening text for the rail's hover card: Markdown marks
    /// dropped, whitespace runs collapsed, at most 180 characters. A direct
    /// UTF-16 pass — this runs for every heading after each edit.
    nonisolated static func railPreview(_ text: NSString, in range: NSRange) -> String {
        var out: [unichar] = []
        out.reserveCapacity(180)
        var space = false
        var i = range.location
        let end = NSMaxRange(range)
        while i < end, out.count < 180 {
            let c = text.character(at: i)
            i += 1
            switch c {
            case 0x23, 0x3E, 0x2A, 0x5F, 0x60, 0x7E, 0x3D, 0x7C, 0x5B, 0x5D, 0x2D: continue   // # > * _ ` ~ = | [ ] -
            case 0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C, 0x85, 0xA0, 0x2028, 0x2029, 0x3000:
                space = !out.isEmpty
                continue
            default: break
            }
            if space { out.append(0x20); space = false; if out.count == 180 { break } }
            out.append(c)
        }
        // Don't end on half of a surrogate pair.
        if let last = out.last, UTF16.isLeadSurrogate(last) { out.removeLast() }
        return String(utf16CodeUnits: out, count: out.count)
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

    /// Y offset for an anchor TextKit has already laid out. This is the
    /// scroll-path variant: it never asks TextKit to settle a missing prefix.
    private func laidOutYOffset(of location: Int, in tv: NSTextView) -> CGFloat? {
        if let tlm = tv.textLayoutManager {
            guard let tcm = tlm.textContentManager,
                  let loc = tcm.location(tcm.documentRange.location, offsetBy: location),
                  let fragment = tlm.textLayoutFragment(for: loc),
                  fragment.state == .layoutAvailable else { return nil }
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
                let railVisible = NativeFindBarLayout.isRailVisible(
                    showsRail: model.showsRail,
                    rawSourceMode: model.rawSource,
                    headingCount: model.railHeadings.count,
                    viewportWidth: geo.size.width,
                    readingWidth: CGFloat(model.readingWidth)
                )
                Group {
                    if railVisible {
                        OutlineRailView(headings: model.railHeadings, current: model.railCurrent) { index, animated in
                            editor.jumpToRailHeading(index, animated: animated)
                        }
                    }
                }
                .onChange(of: railVisible, initial: true) { _, visible in
                    editor.railVisibilityDidChange(visible)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var configuration: MarkdownEditorConfiguration {
        var c = MarkdownEditorConfiguration(
            services: MarkdownEditorServices(images: editor.images, syntaxHighlighter: Self.highlighter, latex: Self.latex,
                                             codeBlockRenderer: Self.mermaid, bus: editor.findBus),
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

private struct NativeFindNotifications {
    let scrollToRange = Notification.Name("Margin.nativeFind.scroll.\(UUID().uuidString)")
    let clearHighlights = Notification.Name("Margin.nativeFind.clear.\(UUID().uuidString)")
}

/// Reports the NSView it is attached to (to locate the engine's text view).
private struct HostViewReader: NSViewRepresentable {
    let onAttach: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        func attach(attempt: Int) {
            DispatchQueue.main.async {
                if let root = v.window?.contentView ?? v.superview?.superview {
                    onAttach(root)
                } else if attempt > 0 {
                    attach(attempt: attempt - 1)
                }
            }
        }
        attach(attempt: 3)
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// A host-owned find bar. AppKit's NSTextFinder installs a separate content
/// dimmer and its result rectangles do not respect the editor's outline rail;
/// owning the controls keeps both concerns in the same coordinate system.
private final class NativeFindBarContainer: NSView, NSSearchFieldDelegate {
    weak var scrollView: NSScrollView?
    private let baseTopInset: CGFloat
    private let searchField = NSSearchField()
    private let resultLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private let replaceToggle = NSButton(checkboxWithTitle: "Replace", target: nil, action: nil)
    private let replaceField = NSTextField()
    private let replaceButton = NSButton(title: "Replace", target: nil, action: nil)
    private let replaceAllButton = NSButton(title: "All", target: nil, action: nil)

    var onLayoutChange: (() -> Void)?
    var onQueryChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?
    var onReplace: ((String) -> Void)?
    var onReplaceAll: ((String) -> Void)?

    var leadingInset = NativeFindBarLayout.railLeadingInset {
        didSet {
            guard leadingInset != oldValue else { return }
            needsLayout = true
        }
    }

    var query: String {
        get { searchField.stringValue }
        set { searchField.stringValue = newValue }
    }

    var showsReplace: Bool { !replaceField.isHidden }

    var isFindBarVisible = false {
        didSet {
            isHidden = !isFindBarVisible
            needsLayout = true
            onLayoutChange?()
        }
    }

    var preferredHeight: CGFloat {
        guard isFindBarVisible else { return 0 }
        return showsReplace ? 63 : 32
    }

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        baseTopInset = scrollView.contentInsets.top
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: scrollView.bounds.width, height: 0)))
        autoresizingMask = [.width]
        isHidden = true
        configureControls()
        scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewFrameDidChange),
            name: NSView.frameDidChangeNotification,
            object: scrollView
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // On its first show AppKit can invalidate the full scroll view before
        // the bar's 32pt frame lands. Clip the fill ourselves so that first
        // pass cannot paint over the document below.
        let barHeight = min(bounds.height, preferredHeight)
        guard barHeight > 0 else { return }
        NSColor.textBackgroundColor.setFill()
        NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: barHeight).fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.minX, y: barHeight - 1, width: bounds.width, height: 1).fill()
    }

    override func layout() {
        super.layout()
        let width = max(0, (scrollView?.bounds.width ?? 0) - leadingInset)
        frame = NSRect(x: leadingInset, y: 0, width: width, height: preferredHeight)
        if let scrollView {
            let oldTop = scrollView.contentInsets.top
            let newTop = baseTopInset + preferredHeight
            if abs(oldTop - newTop) > 0.5 {
                let wasAtTop = abs(scrollView.contentView.bounds.minY + oldTop) < 1
                var insets = scrollView.contentInsets
                insets.top = newTop
                scrollView.contentInsets = insets
                if wasAtTop {
                    let origin = scrollView.contentView.bounds.origin
                    scrollView.contentView.scroll(to: NSPoint(x: origin.x, y: -newTop))
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
        }
        guard isFindBarVisible else { return }

        let margin: CGFloat = 4
        let edgeInset: CGFloat = 6
        let gap: CGFloat = 6
        var right = bounds.width - 8
        replaceToggle.frame = NSRect(x: right - 72, y: 7, width: 72, height: 20)
        right = replaceToggle.frame.minX - gap
        doneButton.frame = NSRect(x: right - 48, y: margin, width: 48, height: 24)
        right = doneButton.frame.minX - gap
        nextButton.frame = NSRect(x: right - 26, y: margin, width: 26, height: 24)
        right = nextButton.frame.minX - 2
        previousButton.frame = NSRect(x: right - 26, y: margin, width: 26, height: 24)
        right = previousButton.frame.minX - gap
        resultLabel.frame = NSRect(x: right - 52, y: 6, width: 52, height: 20)
        right = resultLabel.frame.minX - gap
        searchField.frame = NSRect(x: edgeInset, y: margin, width: max(120, right - edgeInset), height: 24)

        replaceAllButton.frame = NSRect(x: bounds.width - 52, y: 35, width: 44, height: 24)
        replaceButton.frame = NSRect(x: replaceAllButton.frame.minX - gap - 70, y: 35, width: 70, height: 24)
        replaceField.frame = NSRect(x: edgeInset, y: 35,
                                    width: max(120, replaceButton.frame.minX - gap - edgeInset),
                                    height: 24)
    }

    func setReplaceVisible(_ visible: Bool) {
        replaceToggle.state = visible ? .on : .off
        setReplaceRowVisible(visible)
    }

    func setResultCount(_ count: (current: Int, total: Int)?) {
        if let count {
            resultLabel.stringValue = count.current > 0
                ? "\(count.current) of \(count.total)" : "\(count.total) matches"
            resultLabel.textColor = .secondaryLabelColor
        } else if !query.isEmpty {
            resultLabel.stringValue = "None"
            resultLabel.textColor = .systemRed
        } else {
            resultLabel.stringValue = ""
            resultLabel.textColor = .secondaryLabelColor
        }
    }

    func focusSearch() {
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    func focusReplace() {
        guard showsReplace else { return focusSearch() }
        window?.makeFirstResponder(replaceField)
        replaceField.selectText(nil)
    }

    private func configureControls() {
        searchField.placeholderString = "Find"
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.delegate = self
        searchField.setAccessibilityLabel("Find")

        resultLabel.alignment = .right
        resultLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        resultLabel.textColor = .secondaryLabelColor

        configureArrow(previousButton, symbol: "chevron.left", label: "Previous",
                       action: #selector(previousPressed))
        configureArrow(nextButton, symbol: "chevron.right", label: "Next",
                       action: #selector(nextPressed))

        doneButton.target = self
        doneButton.action = #selector(closePressed)
        doneButton.bezelStyle = .rounded
        doneButton.controlSize = .small

        replaceToggle.target = self
        replaceToggle.action = #selector(replaceToggleChanged)
        replaceToggle.controlSize = .small

        replaceField.placeholderString = "Replace"
        replaceField.delegate = self
        replaceField.setAccessibilityLabel("Replace with")

        replaceButton.target = self
        replaceButton.action = #selector(replacePressed)
        replaceButton.bezelStyle = .rounded
        replaceButton.controlSize = .small
        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAllPressed)
        replaceAllButton.bezelStyle = .rounded
        replaceAllButton.controlSize = .small
        replaceAllButton.toolTip = "Replace All"

        [searchField, resultLabel, previousButton, nextButton, doneButton, replaceToggle,
         replaceField, replaceButton, replaceAllButton].forEach(addSubview)
        setReplaceRowVisible(false)
    }

    @objc private func scrollViewFrameDidChange() {
        needsLayout = true
        layoutSubtreeIfNeeded()
        onLayoutChange?()
    }

    private func configureArrow(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = action
        button.toolTip = label
    }

    private func setReplaceRowVisible(_ visible: Bool) {
        replaceField.isHidden = !visible
        replaceButton.isHidden = !visible
        replaceAllButton.isHidden = !visible
        needsLayout = true
        onLayoutChange?()
    }

    @objc private func searchChanged() {
        onQueryChange?(query)
    }

    @objc private func nextPressed() {
        onNext?()
    }

    @objc private func previousPressed() {
        onPrevious?()
    }

    @objc private func closePressed() {
        onClose?()
    }

    @objc private func replaceToggleChanged() {
        setReplaceRowVisible(replaceToggle.state == .on)
        if replaceToggle.state == .on { focusReplace() } else { focusSearch() }
    }

    @objc private func replacePressed() {
        onReplace?(replaceField.stringValue)
    }

    @objc private func replaceAllPressed() {
        onReplaceAll?(replaceField.stringValue)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        onQueryChange?(query)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }
        // Tab and ⇧Tab move between Find and Replace while both are showing,
        // instead of leaving the bar for the document.
        if showsReplace, commandSelector == #selector(NSResponder.insertTab(_:))
            || commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            control === searchField ? focusReplace() : focusSearch()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if control === searchField {
                NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? onPrevious?() : onNext?()
            } else if control === replaceField {
                onReplace?(replaceField.stringValue)
            }
            return true
        }
        return false
    }
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
