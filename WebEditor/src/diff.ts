// Changes since the last git commit, shown inside the editor: added and
// rewritten blocks are tinted green (changed words stronger), removed blocks
// appear as red read-only "ghosts" where they used to be, and every change
// has a button that puts the committed version back (undoable).
//
// The committed document comes from native as Markdown and is parsed with the
// same parser as the open document, so unchanged blocks compare equal. Blocks
// are the top-level nodes; inside a list that changed, its items.
import { Extension } from '@tiptap/core'
import { Plugin, PluginKey, type EditorState, type Transaction } from '@tiptap/pm/state'
import { Decoration, DecorationSet, type EditorView } from '@tiptap/pm/view'
import { DOMSerializer, Fragment, type Node as PMNode, type Schema } from '@tiptap/pm/model'

export interface Hunk {
  /** Range of the replacing nodes in the current document (from == to: only removals). */
  from: number
  to: number
  /** The committed nodes this range replaces. */
  old: PMNode[]
  /** Positions of the added/rewritten nodes. */
  added: { from: number; to: number }[]
  /** Changed words: ranges in the current document, and [start, end) offsets in the old text. */
  addedWords: { from: number; to: number }[]
  removedWords: [number, number][]
  /** For changed list items: the list type they sit in. */
  list?: string
}

interface DiffState {
  base: PMNode | null
  hunks: Hunk[]
  decorations: DecorationSet
  /** Built for the current document (not just mapped through edits). */
  fresh: boolean
}

export const diffKey = new PluginKey<DiffState>('gitDiff')

const LISTS = new Set(['bulletList', 'orderedList', 'taskList'])
const RECOMPUTE_DELAY = 150

/** Called after the changes of the shown document were recomputed. */
let onChanges: ((count: number) => void) | null = null
export function setChangesListener(fn: ((count: number) => void) | null) { onChanges = fn }

/** Sets (or clears, with null) the committed document to compare against. */
export function setDiffBase(tr: Transaction, base: PMNode | null) {
  return tr.setMeta(diffKey, { base }).setMeta('addToHistory', false).setMeta('margin-external', true)
}

export function diffHunks(state: EditorState): Hunk[] {
  return diffKey.getState(state)?.hunks ?? []
}

/** The transaction that puts hunk `index` back to its committed version. */
export function revertHunk(state: EditorState, index: number): Transaction | null {
  const hunk = diffHunks(state)[index]
  if (!hunk) return null
  const tr = state.tr
  if (hunk.old.length) {
    tr.replaceWith(hunk.from, hunk.to, Fragment.from(hunk.old))
  } else if (hunk.from === 0 && hunk.to === state.doc.content.size) {
    tr.replaceWith(0, hunk.to, state.schema.nodes.paragraph.create())
  } else {
    tr.delete(hunk.from, hunk.to)
  }
  return tr.setMeta(diffKey, { recompute: true })
}

export const GitDiff = Extension.create({
  name: 'gitDiff',
  addProseMirrorPlugins() {
    const schema = this.editor.schema
    let timer: number | undefined
    return [new Plugin<DiffState>({
      key: diffKey,
      state: {
        init: () => ({ base: null, hunks: [], decorations: DecorationSet.empty, fresh: true }),
        apply(tr, value, _old, state) {
          const meta = tr.getMeta(diffKey) as { base?: PMNode | null; recompute?: boolean } | undefined
          const base = meta && 'base' in meta ? meta.base ?? null : value.base
          if (!base) return value.base ? { base: null, hunks: [], decorations: DecorationSet.empty, fresh: true } : value
          if (meta) return build(state.doc, base, schema)
          if (!tr.docChanged) return value
          // Until the debounced recompute: keep the marks where the text went.
          return {
            base,
            hunks: value.hunks.map(h => mapHunk(h, tr)),
            decorations: value.decorations.map(tr.mapping, tr.doc),
            fresh: false,
          }
        },
      },
      props: {
        decorations: state => diffKey.getState(state)?.decorations,
      },
      view: () => ({
        update(view, prev) {
          const now = diffKey.getState(view.state)!
          const before = diffKey.getState(prev)
          if (now.base && !now.fresh && now !== before) {
            if (timer !== undefined) clearTimeout(timer)
            timer = window.setTimeout(() => {
              timer = undefined
              if (diffKey.getState(view.state)?.base) view.dispatch(view.state.tr.setMeta(diffKey, { recompute: true }).setMeta('margin-external', true).setMeta('addToHistory', false))
            }, RECOMPUTE_DELAY)
          }
          if (now !== before && (now.hunks !== before?.hunks || now.base !== before?.base)) {
            onChanges?.(now.base ? now.hunks.length : -1)
          }
        },
        destroy() { if (timer !== undefined) clearTimeout(timer) },
      }),
    })]
  },
})

// ---------------------------------------------------------------------------
// Diff

interface Unit { node: PMNode; pos: number }

const keys = new WeakMap<PMNode, string>()
function key(node: PMNode) {
  let k = keys.get(node)
  if (k === undefined) { k = JSON.stringify(node.toJSON()); keys.set(node, k) }
  return k
}

function children(node: PMNode, start: number): Unit[] {
  const out: Unit[] = []
  node.forEach((child, offset) => out.push({ node: child, pos: start + offset }))
  return out
}

export function computeHunks(doc: PMNode, base: PMNode): Hunk[] {
  const hunks: Hunk[] = []
  diffUnits(children(base, 0), children(doc, 0), doc.content.size, hunks, true)
  return hunks
}

function diffUnits(oldUnits: Unit[], newUnits: Unit[], end: number, hunks: Hunk[], topLevel: boolean) {
  const pairs = matches(oldUnits.map(u => key(u.node)), newUnits.map(u => key(u.node)))
  let oi = 0, ni = 0
  for (const [mo, mn] of [...pairs, [oldUnits.length, newUnits.length]]) {
    if (mo > oi || mn > ni) {
      const at = mn < newUnits.length ? newUnits[mn].pos : end
      for (const [oldRun, newRun, insertAt] of refine(oldUnits.slice(oi, mo), newUnits.slice(ni, mn), at)) {
        // One list rewritten into another of the same kind: compare its items.
        if (topLevel && oldRun.length === 1 && newRun.length === 1 &&
            LISTS.has(oldRun[0].node.type.name) && oldRun[0].node.type === newRun[0].node.type &&
            oldRun[0].node.attrs.start === newRun[0].node.attrs.start) {
          const list = newRun[0]
          const start = hunks.length
          diffUnits(children(oldRun[0].node, 0), children(list.node, list.pos + 1),
                    list.pos + list.node.nodeSize - 1, hunks, false)
          for (let i = start; i < hunks.length; i++) hunks[i].list = list.node.type.name
        } else {
          hunks.push(hunk(oldRun.map(u => u.node), newRun, insertAt))
        }
      }
    }
    oi = mo + 1
    ni = mn + 1
  }
}

/**
 * Splits a run of replaced blocks where an old and a new block are the same
 * kind and mostly the same words, so each rewrite is its own change (with
 * its own ghost and restore button) instead of one big block of red and
 * green. Returns [old, new, insert position] runs in document order.
 */
function refine(oldRun: Unit[], newRun: Unit[], end: number): [Unit[], Unit[], number][] {
  if (!oldRun.length || !newRun.length || oldRun.length * newRun.length > 2500) return [[oldRun, newRun, end]]
  const words = (u: Unit) => new Set(u.node.textContent.toLowerCase().match(/[\p{L}\p{N}_']+|[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af]/gu) ?? [])
  const wa = oldRun.map(words), wb = newRun.map(words)
  const similar = (i: number, j: number) => {
    if (oldRun[i].node.type !== newRun[j].node.type) return false
    if (LISTS.has(oldRun[i].node.type.name)) return true
    const a = wa[i], b = wb[j]
    if (!a.size || !b.size) return a.size === b.size
    let common = 0
    for (const w of a) if (b.has(w)) common++
    return common * 2 >= Math.max(a.size, b.size)
  }
  const pairs = lcsBy(oldRun.length, newRun.length, similar)
  if (!pairs.length) return [[oldRun, newRun, end]]
  const out: [Unit[], Unit[], number][] = []
  let oi = 0, ni = 0
  for (const [i, j] of pairs) {
    if (i > oi || j > ni) out.push([oldRun.slice(oi, i), newRun.slice(ni, j), newRun[j].pos])
    out.push([[oldRun[i]], [newRun[j]], newRun[j].pos])
    oi = i + 1; ni = j + 1
  }
  if (oi < oldRun.length || ni < newRun.length) out.push([oldRun.slice(oi), newRun.slice(ni), end])
  return out
}

/** Longest common subsequence under a match predicate, as index pairs. */
function lcsBy(n: number, m: number, match: (i: number, j: number) => boolean): [number, number][] {
  const dp = new Uint16Array((n + 1) * (m + 1))
  for (let i = n - 1; i >= 0; i--)
    for (let j = m - 1; j >= 0; j--)
      dp[i * (m + 1) + j] = match(i, j) ? dp[(i + 1) * (m + 1) + j + 1] + 1 : Math.max(dp[(i + 1) * (m + 1) + j], dp[i * (m + 1) + j + 1])
  const out: [number, number][] = []
  let i = 0, j = 0
  while (i < n && j < m) {
    if (match(i, j) && dp[i * (m + 1) + j] === dp[(i + 1) * (m + 1) + j + 1] + 1) { out.push([i, j]); i++; j++ }
    else if (dp[(i + 1) * (m + 1) + j] >= dp[i * (m + 1) + j + 1]) i++
    else j++
  }
  return out
}

function hunk(old: PMNode[], added: Unit[], insertAt: number): Hunk {
  const from = added.length ? added[0].pos : insertAt
  const to = added.length ? added[added.length - 1].pos + added[added.length - 1].node.nodeSize : insertAt
  const h: Hunk = { from, to, old, added: added.map(u => ({ from: u.pos, to: u.pos + u.node.nodeSize })),
                    addedWords: [], removedWords: [] }
  if (old.length && added.length) {
    const a = textOf(old.map(n => ({ node: n, pos: 0 })))
    const b = textOf(added)
    const [removed, inserted] = wordDiff(a.text, b.text)
    h.removedWords = removed
    h.addedWords = inserted.map(([s, e]) => ({ from: b.positions[s], to: b.positions[e - 1] + 1 }))
  }
  return h
}

/** The text of some nodes (blocks joined by newlines) and each character's position. */
function textOf(units: Unit[]) {
  let text = ''
  const positions: number[] = []
  for (const { node, pos } of units) {
    node.descendants((child, offset) => {
      if (child.isText) {
        for (let i = 0; i < child.text!.length; i++) positions.push(pos + 1 + offset + i)
        text += child.text
      } else if (child.isBlock && text && !text.endsWith('\n')) {
        text += '\n'
        positions.push(-1)
      }
      return true
    })
    if (text && !text.endsWith('\n')) { text += '\n'; positions.push(-1) }
  }
  return { text, positions }
}

function mapHunk(h: Hunk, tr: Transaction): Hunk {
  const m = tr.mapping
  return {
    ...h,
    from: m.map(h.from, -1), to: m.map(h.to, 1),
    added: h.added.map(r => ({ from: m.map(r.from, -1), to: m.map(r.to, 1) })),
    addedWords: h.addedWords.map(r => ({ from: m.map(r.from, 1), to: m.map(r.to, -1) })),
  }
}

/** Matched (old, new) index pairs: patience diff over block keys. */
export function matches(a: string[], b: string[]): [number, number][] {
  const out: [number, number][] = []
  align(a, b, 0, a.length, 0, b.length, out)
  return out
}

function align(a: string[], b: string[], lo: number, hi: number, loB: number, hiB: number, out: [number, number][]) {
  while (lo < hi && loB < hiB && a[lo] === b[loB]) out.push([lo++, loB++])
  const tail: [number, number][] = []
  while (hi > lo && hiB > loB && a[hi - 1] === b[hiB - 1]) tail.push([--hi, --hiB])
  if (lo < hi && loB < hiB) {
    const countA = new Map<string, number>(), countB = new Map<string, number>(), indexB = new Map<string, number>()
    for (let i = lo; i < hi; i++) countA.set(a[i], (countA.get(a[i]) ?? 0) + 1)
    for (let j = loB; j < hiB; j++) { countB.set(b[j], (countB.get(b[j]) ?? 0) + 1); indexB.set(b[j], j) }
    const candidates: [number, number][] = []
    for (let i = lo; i < hi; i++) if (countA.get(a[i]) === 1 && countB.get(a[i]) === 1) candidates.push([i, indexB.get(a[i])!])
    const anchors = longestIncreasing(candidates)
    if (anchors.length) {
      let pa = lo, pb = loB
      for (const [i, j] of anchors) {
        align(a, b, pa, i, pb, j, out)
        out.push([i, j])
        pa = i + 1; pb = j + 1
      }
      align(a, b, pa, hi, pb, hiB, out)
    } else if ((hi - lo) * (hiB - loB) <= 250_000) {
      for (const [x, y] of lcs(a.slice(lo, hi), b.slice(loB, hiB))) out.push([lo + x, loB + y])
    }
  }
  for (let k = tail.length - 1; k >= 0; k--) out.push(tail[k])
}

function longestIncreasing(pairs: [number, number][]): [number, number][] {
  const tops: number[] = []
  const previous = new Array<number>(pairs.length).fill(-1)
  pairs.forEach((pair, k) => {
    let low = 0, high = tops.length
    while (low < high) {
      const mid = (low + high) >> 1
      if (pairs[tops[mid]][1] < pair[1]) low = mid + 1; else high = mid
    }
    if (low > 0) previous[k] = tops[low - 1]
    tops[low] = k
  })
  const out: [number, number][] = []
  for (let k = tops.length ? tops[tops.length - 1] : -1; k >= 0; k = previous[k]) out.push(pairs[k])
  return out.reverse()
}

/** Matched index pairs of a longest common subsequence (small inputs only). */
function lcs<T>(a: T[], b: T[]): [number, number][] {
  const n = a.length, m = b.length
  const dp = new Uint32Array((n + 1) * (m + 1))
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      dp[i * (m + 1) + j] = a[i] === b[j] ? dp[(i + 1) * (m + 1) + j + 1] + 1
        : Math.max(dp[(i + 1) * (m + 1) + j], dp[i * (m + 1) + j + 1])
    }
  }
  const out: [number, number][] = []
  let i = 0, j = 0
  while (i < n && j < m) {
    if (a[i] === b[j]) { out.push([i, j]); i++; j++ }
    else if (dp[(i + 1) * (m + 1) + j] >= dp[i * (m + 1) + j + 1]) i++
    else j++
  }
  return out
}

const CJK = /[぀-ヿ㐀-䶿一-鿿가-힯豈-﫿]/
const TOKEN = /\s+|[\p{L}\p{N}_']+|[^]/gu

/** Words, single CJK characters, punctuation and whitespace runs, as [start, end). */
export function tokens(s: string): [number, number][] {
  const out: [number, number][] = []
  for (const m of s.matchAll(TOKEN)) {
    const t = m[0], start = m.index!
    if (CJK.test(t) && t.length > 1) {
      // CJK has no spaces: split runs into characters (and Latin parts).
      let i = 0
      for (const part of t.match(/[぀-ヿ㐀-䶿一-鿿가-힯豈-﫿]|[^぀-ヿ㐀-䶿一-鿿가-힯豈-﫿]+/g)!) {
        out.push([start + i, start + i + part.length]); i += part.length
      }
    } else {
      out.push([start, start + t.length])
    }
  }
  return out
}

/** Changed words between two rewrites, or none when they share too little. */
export function wordDiff(a: string, b: string): [[number, number][], [number, number][]] {
  const ta = tokens(a), tb = tokens(b)
  if (ta.length * tb.length > 1_000_000) return [[], []]
  const sa = ta.map(([s, e]) => a.slice(s, e)), sb = tb.map(([s, e]) => b.slice(s, e))
  const kept = lcs(sa, sb)
  const keptA = new Set(kept.map(p => p[0])), keptB = new Set(kept.map(p => p[1]))
  const isWord = (t: string) => /\S/.test(t)
  const wordsA = sa.filter(isWord).length, wordsB = sb.filter(isWord).length
  const common = kept.filter(([x]) => isWord(sa[x])).length
  if (!common || common * 3 < Math.max(wordsA, wordsB)) return [[], []]
  const pick = (t: [number, number][], s: string[], keep: Set<number>, text: string) =>
    merge(t.filter((_, i) => !keep.has(i) && isWord(s[i]) && s[i] !== '\n'), text)
  return [pick(ta, sa, keptA, a), pick(tb, sb, keptB, b)]
}

function merge(ranges: [number, number][], text: string): [number, number][] {
  const out: [number, number][] = []
  for (const r of ranges) {
    const last = out[out.length - 1]
    if (last && /^[ \t]*$/.test(text.slice(last[1], r[0]))) last[1] = r[1]
    else out.push([r[0], r[1]])
  }
  return out
}

// ---------------------------------------------------------------------------
// Decorations

function build(doc: PMNode, base: PMNode, schema: Schema): DiffState {
  const hunks = computeHunks(doc, base)
  const decos: Decoration[] = []
  for (const h of hunks) {
    const id = hash(h.old.map(key).join('\u0000')) + '-' + h.added.length + '-' + (h.list ?? '')
    decos.push(Decoration.widget(h.from, (view, getPos) => control(view, getPos, h), {
      side: -2, key: `diff-control-${id}`, ignoreSelection: true, stopEvent: () => true,
    }))
    if (h.old.length) {
      decos.push(Decoration.widget(h.from, () => ghost(h, schema), {
        side: -1, key: `diff-ghost-${id}-${h.removedWords.map(r => r.join(':')).join(',')}`,
        ignoreSelection: true, stopEvent: () => true,
      }))
    }
    for (const r of h.added) decos.push(Decoration.node(r.from, r.to, { class: 'diff-added' }))
    for (const r of h.addedWords) if (r.to > r.from) decos.push(Decoration.inline(r.from, r.to, { class: 'diff-word-added' }))
  }
  return { base, hunks, decorations: DecorationSet.create(doc, decos), fresh: true }
}

function hash(s: string) {
  let h = 5381
  for (let i = 0; i < s.length; i++) h = (h * 33 + s.charCodeAt(i)) | 0
  return (h >>> 0).toString(36) + s.length.toString(36)
}

/** The removed nodes, rendered like the document but read-only. */
function ghost(h: Hunk, schema: Schema): HTMLElement {
  const serializer = DOMSerializer.fromSchema(schema)
  const wrap = document.createElement('div')
  wrap.className = 'diff-ghost' + (h.list ? ' diff-ghost-items' : '')
  wrap.contentEditable = 'false'
  wrap.setAttribute('aria-label', 'Removed since the last commit')
  if (h.list) {
    // Items only render as items inside a list of their kind.
    const list = serializer.serializeNode(schema.nodes[h.list].create(null, h.old)) as HTMLElement
    wrap.appendChild(list)
  } else {
    for (const n of h.old) wrap.appendChild(serializer.serializeNode(n))
  }
  for (const box of wrap.querySelectorAll('input')) (box as HTMLInputElement).disabled = true
  markWords(wrap, h)
  return wrap
}

/** Wraps the removed words of the ghost, when its text matches the diffed text. */
function markWords(root: HTMLElement, h: Hunk) {
  if (!h.removedWords.length) return
  const { text } = textOf(h.old.map(n => ({ node: n, pos: 0 })))
  // Map offsets in `text` (which has '\n' between blocks) to DOM text.
  const skip: number[] = []
  let flat = ''
  for (let i = 0; i < text.length; i++) {
    if (text[i] === '\n') continue
    skip.push(i)
    flat += text[i]
  }
  const walker = document.createTreeWalker(root, 4 /* NodeFilter.SHOW_TEXT */)
  const nodes: Text[] = []
  let dom = ''
  for (let n = walker.nextNode(); n; n = walker.nextNode()) { nodes.push(n as Text); dom += n.nodeValue }
  if (dom !== flat) return
  const flatIndex = new Map(skip.map((orig, i) => [orig, i]))
  const ranges = h.removedWords.map(([s, e]) => {
    let fs = s; while (fs < e && !flatIndex.has(fs)) fs++
    let fe = e - 1; while (fe > fs && !flatIndex.has(fe)) fe--
    return [flatIndex.get(fs), flatIndex.get(fe)] as [number | undefined, number | undefined]
  }).filter((r): r is [number, number] => r[0] !== undefined && r[1] !== undefined)
  // Wrap from the end so earlier offsets stay valid.
  for (const [start, last] of ranges.reverse()) wrapRange(nodes, start, last + 1)
}

function wrapRange(nodes: Text[], start: number, end: number) {
  let offset = 0
  for (const node of [...nodes]) {
    const len = node.nodeValue!.length
    const s = Math.max(start, offset), e = Math.min(end, offset + len)
    if (s < e) {
      const range = document.createRange()
      range.setStart(node, s - offset)
      range.setEnd(node, e - offset)
      const span = document.createElement('span')
      span.className = 'diff-word-removed'
      range.surroundContents(span)
    }
    offset += len
  }
}

/** The "restore" button at the top right of a change. */
function control(view: EditorView, getPos: () => number | undefined, h: Hunk): HTMLElement {
  const anchor = document.createElement('div')
  anchor.className = 'diff-control'
  anchor.contentEditable = 'false'
  const button = document.createElement('button')
  button.type = 'button'
  button.className = 'diff-restore'
  button.textContent = '↺'
  button.title = h.added.length && h.old.length ? 'Restore the committed version'
    : h.old.length ? 'Restore the removed text' : 'Remove the added text'
  button.setAttribute('aria-label', button.title)
  button.addEventListener('mousedown', e => e.preventDefault())
  button.addEventListener('click', e => {
    e.preventDefault()
    // Look the change up where the button is now: edits may have moved it.
    const pos = getPos()
    const index = diffHunks(view.state).findIndex(x => x.from === pos)
    const tr = index < 0 ? null : revertHunk(view.state, index)
    if (tr) { view.dispatch(tr); view.focus() }
  })
  anchor.appendChild(button)
  return anchor
}
