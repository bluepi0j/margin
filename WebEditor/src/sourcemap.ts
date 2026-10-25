// Keeping your place across Markdown source mode: maps between positions in
// the rich document and offsets in its Markdown text, block by block (each
// top-level block's text is found in the Markdown), then character by
// character inside the block (its plain text is matched against the
// Markdown, which only adds markup around it).
import type { Editor } from '@tiptap/core'
import type { Node as PMNode } from '@tiptap/pm/model'
import { serializeMarkdown } from './markdown'

/** Where each top-level block of `doc` starts in `markdown`. */
export function blockOffsets(editor: Editor, doc: PMNode, markdown: string): number[] {
  const offsets: number[] = []
  let cursor = 0
  doc.forEach(block => {
    const own = serializeMarkdown(editor, { type: 'doc', content: [block.toJSON()] }).trim()
    // A block may serialize a little differently on its own (escaping, list
    // numbers); its first characters are enough to find it.
    const probe = own.slice(0, 24)
    const at = probe ? markdown.indexOf(probe, cursor) : -1
    const start = at >= 0 ? at : cursor
    offsets.push(start)
    if (at >= 0) cursor = start + Math.min(own.length, Math.max(1, probe.length))
  })
  return offsets
}

function blockAt(doc: PMNode, index: number): { node: PMNode; pos: number } {
  let pos = 0
  for (let i = 0; i < index; i++) pos += doc.child(i).nodeSize
  return { node: doc.child(index), pos }
}

/** The paragraphs (and other textblocks) inside `block`, with where their content starts. */
function textblocks(block: PMNode, blockPos: number): { node: PMNode; start: number }[] {
  if (block.isTextblock) return [{ node: block, start: blockPos + 1 }]
  const out: { node: PMNode; start: number }[] = []
  block.descendants((node, pos) => {
    if (!node.isTextblock) return true
    out.push({ node, start: blockPos + 1 + pos + 1 })
    return false
  })
  return out
}

const text = (node: PMNode, to = node.content.size) => node.textBetween(0, to, '', '')

// Between paragraphs of one block the plain text has a "\n"; in Markdown that
// is a line break (lists, quotes) or a cell border (tables).
const SEP = '\n'
const matches = (textChar: string, mdChar: string) => textChar === mdChar || (textChar === SEP && mdChar === '|')

/** Where `block`'s own text starts in the Markdown: after the opening fence of a code block. */
function contentStart(block: PMNode, markdown: string, offset: number): number {
  if (!block.type.spec.code) return offset
  const line = markdown.indexOf('\n', offset)
  return line >= 0 ? line + 1 : offset
}

/** The block's plain text up to `pos`, paragraphs separated by SEP. */
function textUpTo(block: PMNode, blockPos: number, pos: number): string {
  let out = ''
  for (const { node, start } of textblocks(block, blockPos)) {
    const end = start + node.content.size
    if (pos > end) { out += text(node) + SEP; continue }
    if (pos > start) out += text(node, pos - start)
    break
  }
  return out
}

/** The Markdown offset for document position `pos`. */
export function sourceOffset(doc: PMNode, offsets: number[], markdown: string, pos: number): number {
  if (!doc.childCount || !offsets.length) return 0
  pos = Math.min(pos, doc.content.size)
  const index = Math.min(doc.childCount - 1, doc.resolve(pos).index(0))
  const { node, pos: blockPos } = blockAt(doc, index)
  const end = index + 1 < offsets.length ? offsets[index + 1] : markdown.length
  let m = contentStart(node, markdown, offsets[index])
  for (const ch of textUpTo(node, blockPos, pos)) {
    let at = m
    while (at < end && !matches(ch, markdown[at])) at++
    if (at >= end) break
    m = at + 1
  }
  return m
}

/** The document position for Markdown offset `offset`. */
export function docPosition(doc: PMNode, offsets: number[], markdown: string, offset: number): number {
  if (!doc.childCount || !offsets.length) return 0
  let index = 0
  while (index + 1 < offsets.length && offsets[index + 1] <= offset) index++
  const { node, pos } = blockAt(doc, index)
  const blocks = textblocks(node, pos)
  const full = blocks.map(b => text(b.node)).join(SEP)
  let t = 0
  for (const ch of markdown.slice(contentStart(node, markdown, offsets[index]), offset)) if (t < full.length && matches(full[t], ch)) t++
  // Walk the paragraphs to the one holding character t.
  for (const { node: tb, start } of blocks) {
    const len = text(tb).length
    if (t <= len) return positionInText(tb, start, t)
    t -= len + 1
  }
  const lastBlock = blocks.at(-1)
  return lastBlock ? lastBlock.start + lastBlock.node.content.size : pos
}

/** The position `t` characters into textblock `tb` (content starting at `start`). */
function positionInText(tb: PMNode, start: number, t: number): number {
  let remaining = t
  let found = start
  tb.forEach((child, offset) => {
    if (remaining < 0) return
    const len = child.isText ? child.text!.length : 0
    if (remaining <= len && child.isText) { found = start + offset + remaining; remaining = -1; return }
    remaining -= len
    found = start + offset + child.nodeSize
  })
  return found
}

// --- Measuring the source textarea (it grows to fit, so the page scrolls) ---

function mirrorOf(area: HTMLTextAreaElement): HTMLDivElement {
  const style = getComputedStyle(area)
  const mirror = document.createElement('div')
  for (const prop of ['fontFamily', 'fontSize', 'fontWeight', 'lineHeight', 'letterSpacing', 'tabSize',
    'paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft', 'borderTopWidth', 'borderLeftWidth'] as const) {
    ;(mirror.style as any)[prop] = (style as any)[prop]
  }
  Object.assign(mirror.style, {
    position: 'absolute', visibility: 'hidden', top: '0', left: '-99999px',
    whiteSpace: 'pre-wrap', overflowWrap: 'break-word', boxSizing: 'border-box',
    width: `${area.clientWidth}px`,
  })
  return mirror
}

/** Distance from the textarea's top to the line holding `offset`. */
export function textareaOffsetY(area: HTMLTextAreaElement, offset: number): number {
  const mirror = mirrorOf(area)
  mirror.textContent = area.value.slice(0, offset)
  const mark = document.createElement('span')
  mark.textContent = '​'
  mirror.appendChild(mark)
  document.body.appendChild(mirror)
  const y = mark.offsetTop
  mirror.remove()
  return y
}

/** The offset of the line start shown `y` pixels below the textarea's top. */
export function textareaOffsetAtY(area: HTMLTextAreaElement, y: number): number {
  let lo = 0
  let hi = area.value.length
  while (lo < hi) {
    const mid = Math.ceil((lo + hi) / 2)
    if (textareaOffsetY(area, mid) <= y) lo = mid
    else hi = mid - 1
  }
  return area.value.lastIndexOf('\n', lo - 1) + 1
}
