import SwiftUI

/// Settings window (⌘,): three panes picked from a row of tabs, with
/// previews for the choices you'd want to see rather than read.
struct SettingsView: View {
    @Bindable var prefs: Preferences
    @State private var pane: Pane = .appearance

    enum Pane: String, CaseIterable, Identifiable {
        case appearance, editor, files
        var id: String { rawValue }
        var title: String { ["appearance": "Appearance", "editor": "Editor", "files": "Files"][rawValue]! }
        var symbol: String { ["appearance": "paintpalette", "editor": "character.cursor.ibeam", "files": "folder"][rawValue]! }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(Pane.allCases) { p in
                    PaneTab(pane: p, selected: pane == p) { pane = p }
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) { Rectangle().fill(Chrome.hairline).frame(height: 1) }

            VStack(alignment: .leading, spacing: 22) {
                switch pane {
                case .appearance: appearance
                case .editor: editor
                case .files: files
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .background(Chrome.canvas)
    }

    // MARK: Panes

    @ViewBuilder private var appearance: some View {
        Group {
            Field("Theme") {
                HStack(spacing: 14) {
                    ForEach(Preferences.Appearance.allCases) { a in
                        Card(title: a.title, selected: prefs.appearance == a) { prefs.appearance = a } preview: {
                            ThemePreview(appearance: a)
                        }
                    }
                }
            }
            Field("Font") {
                HStack(spacing: 14) {
                    ForEach([Preferences.FontStyle.sans, .serif, .mono], id: \.self) { f in
                        Card(title: f.title, selected: prefs.fontStyle == f) { prefs.fontStyle = f } preview: {
                            Text("Aa")
                                .font(.system(size: 26, weight: .medium, design: f == .serif ? .serif : (f == .mono ? .monospaced : .default)))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Chrome.sidebar)
                        }
                    }
                }
            }
            Field("Text size") {
                SliderRow(value: $prefs.fontSize, range: Preferences.fontSizes, step: 1,
                          low: "textformat.size.smaller", high: "textformat.size.larger", label: "\(Int(prefs.fontSize)) pt")
            }
            Field("Line width") {
                SliderRow(value: $prefs.contentWidth, range: 560...1200, step: 20,
                          low: "arrow.right.and.line.vertical.and.arrow.left", high: "arrow.left.and.line.vertical.and.arrow.right",
                          label: "\(Int(prefs.contentWidth))")
            }
            ToggleRow(title: "Outline beside the text",
                      detail: "A tick for each heading down the left edge. Hover to preview a section, click to jump.",
                      isOn: $prefs.showOutlineRail)
        }
    }

    @ViewBuilder private var editor: some View {
        Field("Editor") {
            HStack(spacing: 14) {
                // Numbers from measuring both editors on the same documents.
                EngineCard(title: "Web", symbol: "doc.richtext",
                           detail: "True what-you-see-is-what-you-get.",
                           pros: ["No Markdown symbols in sight", "Click into table cells", "/ menu and selection toolbar"],
                           cons: ["About 2× the memory", "~3% CPU idle while in front", "Saving tidies Markdown slightly"],
                           selected: prefs.editorEngine == .web) { prefs.editorEngine = .web }
                EngineCard(title: "Native", symbol: "text.alignleft",
                           detail: "macOS text editing, lighter on resources.",
                           pros: ["Half the memory", "Almost no CPU when idle", "File kept exactly as typed"],
                           cons: ["Syntax shows near the caret", "Tables edited as text (Tab, menu)", "No / menu or selection toolbar"],
                           selected: prefs.editorEngine == .native) { prefs.editorEngine = .native }
            }
        }
        ToggleRow(title: "Save automatically", detail: "Every change is written to disk as you type. No save dialogs.",
                  isOn: $prefs.autosave)
    }

    @ViewBuilder private var files: some View {
        ToggleRow(title: "Reopen windows and tabs on launch", detail: "Pick up exactly where you left off.",
                  isOn: $prefs.restoreSession)
        ToggleRow(title: "Show all files in the sidebar", detail: "Not just Markdown — images and other files too.",
                  isOn: $prefs.showAllFiles)
    }
}

// MARK: - Pieces

private struct PaneTab: View {
    let pane: SettingsView.Pane
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 17))
                    .frame(height: 22)
                Text(pane.title)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(width: 88, height: 52)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Chrome.selected : (hovering ? Chrome.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A label above its control.
private struct Field<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 12.5, weight: .semibold))
            content
        }
    }
}

/// A choice shown as a picture with its name under it.
private struct Card<Preview: View>: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var preview: Preview

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                preview
                    .frame(width: 136, height: 78)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(Chrome.hairline), lineWidth: selected ? 2.5 : 1))
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A tiny Margin window in light, dark, or half of each.
private struct ThemePreview: View {
    let appearance: Preferences.Appearance

    var body: some View {
        switch appearance {
        case .light: window(dark: false)
        case .dark: window(dark: true)
        case .system:
            ZStack {
                window(dark: false)
                window(dark: true).mask(HStack(spacing: 0) { Color.clear; Color.black })
            }
        }
    }

    private func window(dark: Bool) -> some View {
        let sidebar = dark ? Color(white: 0.14) : Color(white: 0.955)
        let canvas = dark ? Color(white: 0.11) : .white
        let ink = dark ? Color.white : Color.black
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 3) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.8)).frame(width: 5, height: 5) }
                }
                .padding(.bottom, 4)
                ForEach(0..<4) { i in
                    RoundedRectangle(cornerRadius: 1).fill(ink.opacity(i == 1 ? 0.35 : 0.15)).frame(width: i == 1 ? 26 : 22, height: 3)
                }
            }
            .padding(8)
            .frame(width: 44, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(sidebar)
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 1.5).fill(ink.opacity(0.75)).frame(width: 44, height: 5)
                ForEach(0..<4) { i in
                    RoundedRectangle(cornerRadius: 1).fill(ink.opacity(0.18)).frame(width: i == 3 ? 40 : 66, height: 3)
                }
            }
            .padding(.top, 14)
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(canvas)
        }
    }
}

private struct EngineCard: View {
    let title: String
    let symbol: String
    let detail: String
    let pros: [String]
    let cons: [String]
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 15))
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                }
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(pros, id: \.self) { point($0, symbol: "checkmark", color: .green) }
                    ForEach(cons, id: \.self) { point($0, symbol: "minus", color: .secondary) }
                }
                .padding(.top, 2)
            }
            .padding(12)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Chrome.sidebar))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(Chrome.hairline), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func point(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 10)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SliderRow: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let low: String
    let high: String
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: low).foregroundStyle(.secondary)
            // Snapped by hand: `step:` would draw a row of tick marks.
            Slider(value: Binding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range)
            Image(systemName: high).foregroundStyle(.secondary)
            Text(label)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

private struct ToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
    }
}
