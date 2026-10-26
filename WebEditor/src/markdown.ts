// Markdown <-> ProseMirror JSON.
//
// Wraps TipTap's MarkdownManager with the things a file editor needs that a
// notes app can live without:
//   - YAML front matter is split off and kept verbatim.
//   - Raw HTML (block and inline) is preserved verbatim instead of being
//     flattened to text.
//   - Escaping on save is minimal, so editing one line does not sprinkle
//     backslashes and &amp; across the rest of the file.
import type { Editor, JSONContent } from '@tiptap/core'
import { INLINE_MATH } from './nodes'

const FRONT_MATTER = /^---[ \t]*\r?\n([\s\S]*?)\r?\n(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/

export function splitFrontMatter(markdown: string): { frontMatter: string | null; body: string } {
  const match = FRONT_MATTER.exec(markdown)
  if (!match) return { frontMatter: null, body: markdown }
  return { frontMatter: match[1], body: markdown.slice(match[0].length) }
}

export function parseMarkdown(editor: Editor, markdown: string): JSONContent {
  const normalized = markdown.replace(/\r\n?/g, '\n')
  const { frontMatter, body } = splitFrontMatter(normalized)
  const doc = editor.markdown!.parse(body) as JSONContent
  doc.content = doc.content ?? []
  if (frontMatter !== null) {
    doc.content.unshift({
      type: 'frontMatter',
      content: frontMatter ? [{ type: 'text', text: frontMatter }] : [],
    })
  }
  if (doc.content.length === 0) doc.content.push({ type: 'paragraph' })
  return normalize(editor, doc)
}

/**
 * TipTap's parser can leave inline nodes (e.g. a standalone image) directly
 * inside block containers. ProseMirror accepts such a document but commands
 * like Enter then silently fail, so wrap stray inline runs in paragraphs.
 */
export function normalize(editor: Editor, node: JSONContent): JSONContent {
  const schema = editor.schema
  const type = node.type ? schema.nodes[node.type] : undefined
  if (!node.content || !type) return node
  const children = node.content.map(child => normalize(editor, child))
  if (type.inlineContent) {
    node.content = children
    return node
  }
  const out: JSONContent[] = []
  let run: JSONContent[] | null = null
  for (const child of children) {
    const childType = child.type === 'text' ? schema.nodes.text : child.type ? schema.nodes[child.type] : undefined
    if (childType?.isInline) {
      if (!run) out.push({ type: 'paragraph', content: (run = []) })
      run.push(child)
    } else {
      run = null
      out.push(child)
    }
  }
  node.content = out
  return node
}

export function serializeMarkdown(editor: Editor, doc: JSONContent): string {
  const content = doc.content ?? []
  let prefix = ''
  let rest = content
  if (content[0]?.type === 'frontMatter') {
    const text = (content[0].content ?? []).map(n => n.text ?? '').join('')
    prefix = `---\n${text}\n---\n\n`
    rest = content.slice(1)
  }
  let body = editor.markdown!.serialize({ ...doc, content: rest })
  body = tidy(body)
  return prefix + body + '\n'
}

/**
 * Cleanup of the serialized body, line by line so it never reaches inside a
 * code fence: TipTap pads tables with extra blank lines and writes `&nbsp;`
 * for empty paragraphs, but collapsing blank lines
 * inside a code block would change the file's content (Python's two blank
 * lines between defs, or literal `&nbsp;` in an HTML snippet). Fences are
 * tracked the CommonMark way: a fence of N characters is only closed by a
 * line of at least N of the same character, so ``` inside a ```` block
 * doesn't confuse the count.
 */
function tidy(body: string): string {
  const out: string[] = []
  let fence = '' // the opening run ('```', '~~~~'…); '' when outside code
  let blanks = 0
  for (let line of body.split('\n')) {
    const m = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line)
    if (fence) {
      if (m && m[1][0] === fence[0] && m[1].length >= fence.length && m[2].trim() === '') fence = ''
    } else if (m) {
      fence = m[1]
    }
    if (fence) {
      blanks = 0
      out.push(line)
      continue
    }
    // TipTap writes `&nbsp;` as a placeholder for each extra empty paragraph;
    // it isn't the user's text, so it becomes a blank line (and collapses).
    if (/^[ >]*&nbsp;$/.test(line)) line = line.replace(/&nbsp;$/, '').trimEnd()
    if (line === '') {
      if (++blanks > 1) continue // two or more blank lines collapse to one
    } else {
      blanks = 0
    }
    out.push(line)
  }
  return out.join('\n').replace(/^\n+/, '').replace(/\s+$/, '')
}

// ---------------------------------------------------------------------------
// Escaping

// Only escape a character when leaving it bare could change how the text
// parses. TipTap's default escapes every `*`, `_`, `[`, `<` and `&`.
export function escapeText(text: string): string {
  let out = ''
  for (let i = 0; i < text.length; i++) {
    const ch = text[i]
    const prev = i > 0 ? text[i - 1] : ''
    const next = i + 1 < text.length ? text[i + 1] : ''
    switch (ch) {
      case '\\':
        out += /[!-\/:-@\[-`{-~]/.test(next) ? '\\\\' : '\\'
        break
      case '`':
        out += '\\`'
        break
      case '*':
      case '~':
      case '_': {
        const spaced = (!prev || /\s/.test(prev)) && (!next || /\s/.test(next))
        const intraword = ch === '_' && /[\p{L}\p{N}]/u.test(prev) && /[\p{L}\p{N}]/u.test(next)
        out += spaced || intraword ? ch : '\\' + ch
        break
      }
      case '=':
        out += next === '=' || prev === '=' ? '\\=' : '='
        break
      case '[':
        out += /^\[[^\]]*\](?:\(|\[|:)/.test(text.slice(i)) || next === '^' ? '\\[' : '['
        break
      case '$':
        // A lone "$5" is fine; "$x$" would turn into math.
        out += INLINE_MATH.test(text.slice(i)) ? '\\$' : '$'
        break
      case '<':
        out += /[A-Za-z\/!?]/.test(next) ? '&lt;' : '<'
        break
      case '&':
        out += /^&(?:#\d+|#x[0-9a-f]+|[a-z][a-z0-9]*);/i.test(text.slice(i)) ? '&amp;' : '&'
        break
      default:
        out += ch
    }
  }
  return out
}

/** Swap TipTap's text encoder for the minimal one above. */
export function installMinimalEscaping(editor: Editor) {
  const manager = editor.markdown as any
  const codeTypes: Set<string> = manager.codeTypes ?? new Set(['code', 'codeBlock'])
  manager.encodeTextForMarkdown = (text: string, node: JSONContent, parent?: JSONContent) => {
    const inCode =
      (parent?.type != null && codeTypes.has(parent.type)) ||
      (node.marks ?? []).some((m: any) => codeTypes.has(typeof m === 'string' ? m : m.type))
    return inCode ? text : escapeText(text)
  }
  // Raw HTML stays raw: block HTML becomes an htmlBlock node, inline HTML an
  // htmlInline atom. Both serialize back byte for byte.
  manager.parseHTMLToken = (token: any) => {
    const html: string = token.raw ?? token.text ?? ''
    if (!html.trim()) return null
    if (token.block) {
      return { type: 'htmlBlock', content: [{ type: 'text', text: html.replace(/\s+$/, '') }] }
    }
    return { type: 'htmlInline', attrs: { html } }
  }
}
