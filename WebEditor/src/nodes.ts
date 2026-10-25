// Custom nodes that keep non-WYSIWYG Markdown intact: front matter, raw HTML
// and footnotes. They render as quiet, clearly "raw" blocks you can still edit.
import { Node, mergeAttributes, InputRule } from '@tiptap/core'
import { BlockMath, InlineMath } from '@tiptap/extension-mathematics'

/** YAML front matter. Only ever the first node; parsed/serialized in markdown.ts. */
export const FrontMatter = Node.create({
  name: 'frontMatter',
  group: 'block',
  content: 'text*',
  marks: '',
  code: true,
  defining: true,
  isolating: true,
  parseHTML: () => [{ tag: 'pre[data-type="front-matter"]', preserveWhitespace: 'full' }],
  renderHTML: ({ HTMLAttributes }) => [
    'pre',
    mergeAttributes(HTMLAttributes, { 'data-type': 'front-matter', class: 'raw-block', 'data-label': 'Front matter' }),
    ['code', 0],
  ],
  // Rendered by serializeMarkdown; this keeps the generic serializer quiet.
  renderMarkdown: () => '',
})

/** A block of raw HTML, kept verbatim. */
export const HtmlBlock = Node.create({
  name: 'htmlBlock',
  group: 'block',
  content: 'text*',
  marks: '',
  code: true,
  defining: true,
  isolating: true,
  parseHTML: () => [{ tag: 'pre[data-type="html-block"]', preserveWhitespace: 'full' }],
  renderHTML: ({ HTMLAttributes }) => [
    'pre',
    mergeAttributes(HTMLAttributes, { 'data-type': 'html-block', class: 'raw-block', 'data-label': 'HTML' }),
    ['code', 0],
  ],
  renderMarkdown: (node: any) => (node.content ?? []).map((n: any) => n.text ?? '').join(''),
})

/** Inline raw HTML such as <br> or <kbd>⌘</kbd>, kept verbatim. */
export const HtmlInline = Node.create({
  name: 'htmlInline',
  group: 'inline',
  inline: true,
  atom: true,
  selectable: true,
  addAttributes: () => ({ html: { default: '' } }),
  parseHTML: () => [{ tag: 'span[data-type="html-inline"]', getAttrs: el => ({ html: (el as HTMLElement).textContent }) }],
  renderHTML: ({ node }) => ['span', { 'data-type': 'html-inline', class: 'raw-inline' }, node.attrs.html],
  renderMarkdown: (node: any) => node.attrs?.html ?? '',
})

/** Footnote reference: [^label] */
export const FootnoteRef = Node.create({
  name: 'footnoteRef',
  group: 'inline',
  inline: true,
  atom: true,
  addAttributes: () => ({ label: { default: '' } }),
  parseHTML: () => [{ tag: 'sup[data-type="footnote-ref"]', getAttrs: el => ({ label: (el as HTMLElement).dataset.label }) }],
  renderHTML: ({ node }) => ['sup', { 'data-type': 'footnote-ref', 'data-label': node.attrs.label, class: 'footnote-ref' }, node.attrs.label],
  markdownTokenizer: {
    name: 'footnoteRef',
    level: 'inline',
    start: (src: string) => src.indexOf('[^'),
    tokenize: (src: string) => {
      const m = /^\[\^([^\]\s]+)\](?!:)/.exec(src)
      return m ? { type: 'footnoteRef', raw: m[0], label: m[1] } : undefined
    },
  },
  parseMarkdown: (token: any) => ({ type: 'footnoteRef', attrs: { label: token.label } }),
  renderMarkdown: (node: any) => `[^${node.attrs?.label ?? ''}]`,
} as any)

/** Footnote definition: [^label]: text */
export const FootnoteDef = Node.create({
  name: 'footnoteDef',
  group: 'block',
  content: 'inline*',
  defining: true,
  addAttributes: () => ({ label: { default: '' } }),
  parseHTML: () => [{ tag: 'div[data-type="footnote-def"]', getAttrs: el => ({ label: (el as HTMLElement).dataset.label }) }],
  renderHTML: ({ node }) => ['div', { 'data-type': 'footnote-def', 'data-label': node.attrs.label, class: 'footnote-def' }, 0],
  markdownTokenizer: {
    name: 'footnoteDef',
    level: 'block',
    start: (src: string) => src.search(/^\[\^[^\]\s]+\]:/m),
    tokenize: (src: string, _tokens: any, lexer: any) => {
      const m = /^\[\^([^\]\s]+)\]:[ \t]*((?:[^\n]*)(?:\n(?: {2,}|\t)[^\n]*)*)(?:\n|$)/.exec(src)
      if (!m) return undefined
      const text = m[2].replace(/\n(?: {2,}|\t)/g, ' ')
      return { type: 'footnoteDef', raw: m[0], label: m[1], text, tokens: lexer.inlineTokens(text) }
    },
  },
  parseMarkdown: (token: any, h: any) => ({
    type: 'footnoteDef',
    attrs: { label: token.label },
    content: h.parseInline(token.tokens ?? []),
  }),
  renderMarkdown: (node: any, h: any) => `[^${node.attrs?.label ?? ''}]: ${h.renderChildren(node)}`,
} as any)

// Math: Markdown uses $x$ and $$x$$; the stock input rules expect $$x$$ and
// $$$x$$$. Typing `$x$` makes inline math, `$$x$$` on its own line block math.
// Pandoc's rule: no space just inside the dollars, and the closing $ is not
// followed by a digit -- so "$5 and $10" stays text.
export const INLINE_MATH = /^\$(?![\s$])((?:\\.|[^$\n\\])+?)(?<!\s)\$(?![\d$])/

export const MarginInlineMath = InlineMath.extend({
  markdownTokenizer: {
    name: 'inlineMath',
    level: 'inline',
    start: (src: string) => src.indexOf('$'),
    tokenize: (src: string) => {
      const m = INLINE_MATH.exec(src)
      return m ? { type: 'inlineMath', raw: m[0], latex: m[1] } : undefined
    },
  },
  addInputRules() {
    return [
      new InputRule({
        find: /(?:^|[^$\\])(\$([^\s$](?:[^$\n]*[^\s$])?)\$)$/,
        handler: ({ state, range, match }) => {
          const latex = match[2]
          const start = range.to - match[1].length
          state.tr.replaceWith(start, range.to, this.type.create({ latex }))
        },
      }),
    ]
  },
})

export const MarginBlockMath = BlockMath.extend({
  addInputRules() {
    return [
      new InputRule({
        find: /^\$\$([^$]+)\$\$$/,
        handler: ({ state, range, match }) => {
          const $from = state.doc.resolve(range.from)
          const from = $from.before()
          const to = $from.after()
          state.tr.replaceWith(from, to, this.type.create({ latex: match[1].trim() }))
        },
      }),
    ]
  },
})
