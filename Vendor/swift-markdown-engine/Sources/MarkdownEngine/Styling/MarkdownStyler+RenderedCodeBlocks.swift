//
//  MarkdownStyler+RenderedCodeBlocks.swift
//  MarkdownEngine
//
//  [Margin patch] Fenced code blocks drawn as images by the embedder's
//  `CodeBlockRenderer` (```mermaid → a diagram). Same machinery as block
//  LaTeX: while the caret is outside the block its source collapses and the
//  image stands in; inside, it is ordinary highlighted code.
//

import AppKit
import Foundation

extension MarkdownStyler {

    static func styleRenderedCodeBlocks(_ ctx: StylingContext) -> [StyledRange] {
        guard let renderer = ctx.services.codeBlockRenderer else { return [] }
        var attrs: [StyledRange] = []
        let maxWidth = ctx.configuration.readingWidth ?? 640
        for (idx, token) in ctx.scoped(StylingContext.indexed(ctx.tokens, .codeBlock)) {
            guard token.markerRanges.count == 2, !ctx.activeTokenIndices.contains(idx) else { continue }
            let openFence = ctx.nsText.substring(with: token.markerRanges[0])
            let language = openFence.drop { $0 == "`" }
                .split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } ?? ""
            guard renderer.renders(language: language) else { continue }
            let code = ctx.nsText.substring(with: token.contentRange)
            guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let image = renderer.render(code: code, language: language, maxWidth: maxWidth) else { continue }

            // No code-block fill behind the picture.
            attrs.append((token.range, [.backgroundColor: NSColor.clear]))
            _ = appendRenderedStandaloneBlock(
                for: token,
                rawContent: code,
                image: image,
                imageBounds: CGRect(origin: .zero, size: image.size),
                paragraphSpacingBefore: 10,
                paragraphSpacing: 10,
                alignment: .center,
                mode: .collapsedSource(markerTexts: [openFence, ctx.nsText.substring(with: token.markerRanges[1])]),
                ctx: ctx,
                attrs: &attrs
            )
        }
        return attrs
    }
}
