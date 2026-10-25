import SwiftUI

/// The row of formatting buttons above the text (Scratch-style): flat, always
/// visible, one click each. Buttons light up for the formatting at the caret.
struct FormatBar: View {
    let selection: EditorSelection
    let enabled: Bool
    /// Runs an editor command (see `runCommand` in WebEditor/src/editor.ts).
    let run: (_ command: String, _ args: [String: Any]) -> Void
    let pickImage: () -> Void

    struct Item {
        let command: String
        let symbol: String
        let label: String
        let shortcut: String
        var help: String { shortcut.isEmpty ? label : "\(label)  \(shortcut)" }
    }

    static let inline = [
        Item(command: "bold", symbol: "bold", label: "Bold", shortcut: "⌘B"),
        Item(command: "italic", symbol: "italic", label: "Italic", shortcut: "⌘I"),
        Item(command: "strike", symbol: "strikethrough", label: "Strikethrough", shortcut: "⇧⌘X"),
        Item(command: "code", symbol: "chevron.left.forwardslash.chevron.right", label: "Inline Code", shortcut: "⌘E"),
        Item(command: "link", symbol: "link", label: "Link", shortcut: "⌘K"),
    ]
    static let blocks = [
        Item(command: "bulletList", symbol: "list.bullet", label: "Bulleted List", shortcut: "⇧⌘8"),
        Item(command: "orderedList", symbol: "list.number", label: "Numbered List", shortcut: "⇧⌘7"),
        Item(command: "taskList", symbol: "checklist", label: "Task List", shortcut: "⇧⌘9"),
        Item(command: "blockquote", symbol: "text.quote", label: "Quote", shortcut: "⇧⌘B"),
    ]
    static let inserts = [
        Item(command: "codeBlock", symbol: "curlybraces", label: "Code Block", shortcut: "⌥⌘C"),
        Item(command: "blockMath", symbol: "function", label: "Formula", shortcut: "⇧⌥⌘E"),
        Item(command: "inlineMath", symbol: "x.squareroot", label: "Inline Formula", shortcut: "⌥⌘E"),
        Item(command: "table", symbol: "tablecells", label: "Table", shortcut: "⌥⌘T"),
        Item(command: "image", symbol: "photo", label: "Image", shortcut: "⇧⌘I"),
        Item(command: "mermaid", symbol: "flowchart", label: "Diagram (Mermaid)", shortcut: ""),
        Item(command: "horizontalRule", symbol: "minus", label: "Divider", shortcut: ""),
    ]

    var body: some View {
        // Narrow windows fold the inserts into a "+" menu instead of clipping.
        ViewThatFits(in: .horizontal) {
            bar(foldInserts: false)
            bar(foldInserts: true)
        }
        .disabled(!enabled)
    }

    private func bar(foldInserts: Bool) -> some View {
        HStack(spacing: 1) {
            ForEach(1...3, id: \.self) { level in
                ChromeButton(text: "H\(level)", help: "Heading \(level)  ⌥⌘\(level)", active: enabled && selection.heading == level) {
                    run("heading", ["level": selection.heading == level ? 0 : level])
                }
            }
            separator
            buttons(Self.inline)
            separator
            buttons(Self.blocks)
            separator
            if foldInserts {
                Menu {
                    ForEach(Self.inserts, id: \.command) { item in
                        Button { perform(item.command) } label: { Label(item.label, systemImage: item.symbol) }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 28, height: 28)
                .help("Insert")
            } else {
                buttons(Self.inserts, highlight: false)
            }
        }
        .fixedSize()
    }

    private func buttons(_ items: [Item], highlight: Bool = true) -> some View {
        ForEach(items, id: \.command) { item in
            ChromeButton(symbol: item.symbol, help: item.help,
                         active: highlight && enabled && selection.has(item.command)) { perform(item.command) }
        }
    }

    private var separator: some View {
        Rectangle().fill(Chrome.hairline).frame(width: 1, height: 16).padding(.horizontal, 6)
    }

    private func perform(_ command: String) {
        if command == "image" { pickImage() } else { run(command, [:]) }
    }
}
