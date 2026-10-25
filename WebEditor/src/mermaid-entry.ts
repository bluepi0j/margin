// Separate bundle (mermaid.js), loaded only when a document has a Mermaid block.
import { renderMermaidSVG } from 'beautiful-mermaid'

;(window as any).MarginMermaid = {
  render(code: string): string {
    const svg = renderMermaidSVG(code, { bg: 'var(--diagram-bg)', fg: 'var(--diagram-fg)', transparent: true } as any)
    // The SVG asks for a web font from Google; drop it so nothing leaves the
    // machine and diagrams look the same offline (the system font is used).
    return svg.replace(/@import url\([^)]*\);?/g, '').replace(/'Inter',\s*/g, '')
  },
}
