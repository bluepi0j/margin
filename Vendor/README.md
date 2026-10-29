# Vendored packages

## swift-markdown-engine

[nodes-app/swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine)
0.15.0 (Apache 2.0, see its LICENSE), the native editor's engine. Copied here
so Margin can carry small local patches; everything Margin added is marked
`[Margin patch]`:

- `Services/MarkdownEditorServices.swift` — a `CodeBlockRenderer` service.
- `Styling/MarkdownStyler+RenderedCodeBlocks.swift` — draws fenced code blocks
  the renderer accepts (```mermaid) as images, reusing block LaTeX's
  collapse-the-source machinery; called from `MarkdownStyler.styleAttributes`.
- `TextView/NativeTextView/NativeTextView+PasteHandling.swift` — preserves pasted
  Markdown whitespace (leading indentation, trailing spaces and blank lines)
  instead of globally trimming and normalizing it.
- `TextView/NativeTextViewWrapper.swift` — `updateNSView` re-applies a changed
  `readingWidth` (the wrap width was only set in `makeNSView`, so Settings ›
  Line width had no effect until the editor was recreated).

The test targets and demo app are left out. To update: copy a newer release's
`Sources/`, `Package.swift` (minus test targets) and `LICENSE` over this folder
and re-apply the patch. Worth offering upstream.
