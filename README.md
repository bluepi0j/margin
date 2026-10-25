# Margin

A lightweight, clean Markdown editor for macOS. What you see is the file — there is no separate preview — and, like VS Code, each window is a folder with its files open as tabs.

- Two editors, switchable in Settings: **Web** (TipTap, true what-you-see-is-what-you-get) and **Native** (TextKit 2, about half the memory)
- Saves as you type; when another program (an AI agent, say) changes the file, it reloads in place without moving your cursor
- Tables, math, syntax highlighting, Mermaid diagrams, an outline rail beside the text, search across the folder, export to HTML / PDF

## Layout

| Path | What's there |
| --- | --- |
| `Sources/MarginCore/` | Pure logic (open routing, file tree, text commands, table edits…), unit tested |
| `Sources/Margin/` | The app (AppKit + SwiftUI); `Resources/Editor/` is the bundled web editor |
| `WebEditor/` | Source of the web editor (TypeScript + TipTap) |
| `Vendor/` | swift-markdown-engine with a small patch — see `Vendor/README.md` |
| `scripts/` | Build, test, and draw the app icon |

## Getting started

```bash
scripts/build-app.sh      # builds dist/Margin.app
open dist/Margin.app
```

Drag `dist/Margin.app` into Applications to use it day to day. To open `.md` files with Margin from the Finder: right-click a `.md` file → Get Info → Open with → Margin → Change All.

## Tests

```bash
scripts/test.sh
```

## Requirements

- macOS 14 or later
- Xcode (to build the Swift code)
- Node.js 18+ — only when changing the web editor in `WebEditor/`; its built output is already in the repo

## License

[MIT](LICENSE). `Vendor/swift-markdown-engine` is Apache 2.0 (see the LICENSE inside it).
