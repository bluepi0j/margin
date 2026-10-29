// Entry point of the editor page. One page per window; it holds every open
// tab as a separate ProseMirror EditorState and swaps them into a single
// editor view, so switching tabs is instant and keeps per-tab undo history.
//
// Native -> JS: window.margin.*   (see the `api` object below)
// JS -> Native: window.webkit.messageHandlers.margin.postMessage({type, ...})
import 'katex/dist/katex.min.css'
import './styles.css'

import { EditorState, Selection } from '@tiptap/pm/state'
import type { Node as PMNode } from '@tiptap/pm/model'
import { createDocument, type Editor } from '@tiptap/core'
import { createEditor, runCommand, selectionState, setImageBase, renderMermaid } from './editor'
import { parseMarkdown, serializeMarkdown } from './markdown'
import { FindBar } from './find'
import { closePopover } from './popover'
import { BubbleBar } from './bubble'
import { OutlineRail } from './rail'
import { blockOffsets, docPosition, sourceOffset, textareaOffsetAtY, textareaOffsetY } from './sourcemap'

interface Doc {
  id: string
  /** Markdown as last loaded or saved; used before the doc is first shown. */
  markdown: string
  baseURL: string
  state: EditorState | null
  scrollTop: number
  /** Edited since the last time content was posted to native. */
  pending: boolean
  /** Raw text while source mode is on. */
  source: string | null
  /** What `source` was when source mode started, to tell if it was edited. */
  sourceBase: string | null
}

declare global {
  interface Window {
    margin: typeof api & { post: (msg: any) => void }
    webkit?: { messageHandlers?: { margin?: { postMessage: (m: any) => void } } }
  }
}

function post(msg: any) {
  window.webkit?.messageHandlers?.margin?.postMessage(msg)
}

const docs = new Map<string, Doc>()
let activeId: string | null = null
let sourceMode = false
let saveTimer: number | undefined
const SAVE_DELAY = 450

const host = document.getElementById('editor')!
const sourceArea = document.getElementById('source') as HTMLTextAreaElement
const emptyState = document.getElementById('empty')!
const wordCount = document.getElementById('word-count')!
const editor: Editor = createEditor(host)
const blankState = editor.state
const findBar = new FindBar(() => editor)
const bubble = new BubbleBar(editor)
editor.on('blur', () => setTimeout(() => bubble.update(), 0))
const rail = new OutlineRail(() => (activeId && !host.hidden ? host : null))

// ---------------------------------------------------------------------------
// Edits -> native

editor.on('update', ({ transaction }) => {
  if (transaction.getMeta('margin-external')) return
  markEdited()
})

sourceArea.addEventListener('input', () => {
  const doc = active()
  if (!doc) return
  doc.source = sourceArea.value
  markEdited()
  scheduleOutline()
})

function markEdited() {
  const doc = active()
  if (!doc) return
  if (!doc.pending) post({ type: 'edited', id: doc.id })
  doc.pending = true
  clearTimeout(saveTimer)
  saveTimer = window.setTimeout(flush, SAVE_DELAY)
}

function currentMarkdown(doc: Doc): string {
  if (doc.source !== null) return doc.source
  if (doc.id === activeId && !sourceMode) return serializeMarkdown(editor, editor.getJSON())
  if (doc.state) return serializeMarkdown(editor, doc.state.doc.toJSON())
  return doc.markdown
}

/** Posts content for every edited doc; returns it as well for synchronous saves. */
function flush(): Record<string, string> {
  clearTimeout(saveTimer)
  const out: Record<string, string> = {}
  for (const doc of docs.values()) {
    if (!doc.pending) continue
    doc.pending = false
    doc.markdown = currentMarkdown(doc)
    out[doc.id] = doc.markdown
    post({ type: 'content', id: doc.id, markdown: doc.markdown })
  }
  return out
}

// Selection state for the native toolbar, coalesced to one message per frame.
let stateFrame = 0
let lastState = ''
function scheduleState() {
  if (stateFrame) return
  stateFrame = requestAnimationFrame(() => {
    stateFrame = 0
    const s = sourceMode || !activeId ? { source: sourceMode } : { ...selectionState(editor), source: false }
    const json = JSON.stringify(s)
    if (json === lastState) return
    lastState = json
    post({ type: 'selection', state: s })
  })
}
editor.on('transaction', ({ transaction }) => {
  scheduleState()
  bubble.update()
  if (transaction.docChanged) scheduleOutline()
})

// Headings for the sidebar outline, and word count, posted after edits settle.
let outlineTimer: number | undefined
function scheduleOutline() {
  clearTimeout(outlineTimer)
  outlineTimer = window.setTimeout(postOutline, 250)
}

function postOutline() {
  if (!activeId) return post({ type: 'outline', id: null, items: [], words: 0 })
  const items: { level: number; text: string; pos: number }[] = []
  let text = ''
  if (sourceMode) {
    text = sourceArea.value
    const re = /^(#{1,6})\s+(.+)$/gm
    let m
    while ((m = re.exec(text))) items.push({ level: m[1].length, text: m[2].replace(/[*_`~=]/g, ''), pos: m.index })
  } else {
    editor.state.doc.descendants((node, pos) => {
      if (node.type.name === 'heading') items.push({ level: node.attrs.level, text: node.textContent, pos })
      return node.isBlock && node.type.name !== 'heading'
    })
    text = editor.state.doc.textBetween(0, editor.state.doc.content.size, ' ', ' ')
  }
  const words = countWords(text)
  wordCount.textContent = words ? `${words.toLocaleString()} ${words === 1 ? 'word' : 'words'}` : ''
  post({ type: 'outline', id: activeId, items, words })
  rail.rebuild()
}

/** Words for Latin text, plus one per CJK character (how CJK counts are usually given). */
export function countWords(text: string) {
  const cjk = text.match(/[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af]/g)?.length ?? 0
  const latin = text.replace(/[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af]/g, ' ').match(/[\p{L}\p{N}'’-]+/gu)?.length ?? 0
  return cjk + latin
}

// ---------------------------------------------------------------------------
// Doc switching

function active(): Doc | undefined {
  return activeId ? docs.get(activeId) : undefined
}

function stateFor(doc: Doc): EditorState {
  if (!doc.state) {
    doc.state = EditorState.create({ doc: buildDoc(doc.markdown), plugins: editor.state.plugins })
  }
  return doc.state
}

/** Markdown -> a schema-valid ProseMirror document. */
function buildDoc(markdown: string) {
  const json = parseMarkdown(editor, markdown)
  try {
    const node = editor.schema.nodeFromJSON(json)
    node.check()
    return node
  } catch (e) {
    // Let TipTap repair whatever the parser produced rather than refusing to open.
    console.error('Margin: repairing document', e)
    return createDocument(json, editor.schema, undefined, { errorOnInvalidContent: false })
  }
}

/** A transaction that turns `state.doc` into `next`, touching only what differs. */
function patch(state: EditorState, next: PMNode) {
  const old = state.doc
  const start = old.content.findDiffStart(next.content)
  if (start == null) return null
  let { a: endA, b: endB } = old.content.findDiffEnd(next.content)!
  // When the change is a repeat of neighbouring text the ends can cross.
  const overlap = start - Math.min(endA, endB)
  if (overlap > 0) {
    endA += overlap
    endB += overlap
  }
  const tr = state.tr.replace(start, endA, next.slice(start, endB))
  return tr.setMeta('margin-external', true).setMeta('addToHistory', false)
}

function stash() {
  const doc = active()
  if (!doc) return
  doc.scrollTop = document.scrollingElement!.scrollTop
  if (sourceMode) {
    doc.source = sourceArea.value
  } else {
    doc.state = editor.state
  }
}

function show(doc: Doc | undefined) {
  closePopover(false)
  bubble.hide()
  emptyState.hidden = !!doc
  host.hidden = !doc || sourceMode
  sourceArea.hidden = !doc || !sourceMode
  if (!doc) {
    editor.view.updateState(blankState)
    activeId = null
    scheduleState()
    scheduleOutline()
    return
  }
  activeId = doc.id
  setImageBase(doc.baseURL)
  if (sourceMode) {
    if (doc.source === null) doc.source = doc.sourceBase = currentMarkdown(doc)
    sourceArea.value = doc.source
    autosizeSource()
  } else {
    if (doc.source !== null) {
      // Coming back from source mode: rebuild the rich document only if the
      // text was edited, so untouched tabs keep their undo history.
      if (doc.source !== doc.sourceBase) {
        doc.markdown = doc.source
        doc.state = null
      }
      doc.source = doc.sourceBase = null
    }
    editor.view.updateState(stateFor(doc))
  }
  findBar.refresh()
  scheduleState()
  scheduleOutline()
  const top = doc.scrollTop
  requestAnimationFrame(() => (document.scrollingElement!.scrollTop = top))
}

interface Place { markdown: string; caret: number; top: number }

const TOP_MARGIN = 24

/** The caret and the first visible line of the current view, as offsets into its Markdown. */
function placeInMarkdown(): Place {
  if (sourceMode) {
    const areaTop = sourceArea.getBoundingClientRect().top
    return { markdown: sourceArea.value, caret: sourceArea.selectionStart,
             top: textareaOffsetAtY(sourceArea, Math.max(0, TOP_MARGIN - areaTop)) }
  }
  const markdown = serializeMarkdown(editor, editor.getJSON())
  const doc = editor.state.doc
  const offsets = blockOffsets(editor, doc, markdown)
  const box = host.getBoundingClientRect()
  const atTop = editor.view.posAtCoords({ left: box.left + 2, top: Math.max(box.top + 2, TOP_MARGIN) })
  return { markdown, caret: sourceOffset(doc, offsets, markdown, editor.state.selection.from),
           top: sourceOffset(doc, offsets, markdown, atTop?.pos ?? 0) }
}

/** Puts the caret at `place` in the view now showing and scrolls its line to the top. */
function goToPlace(place: Place) {
  let offsets: number[] = []
  if (sourceMode) {
    sourceArea.setSelectionRange(place.caret, place.caret)
  } else {
    const doc = editor.state.doc
    offsets = blockOffsets(editor, doc, place.markdown)
    const caret = docPosition(doc, offsets, place.markdown, place.caret)
    editor.view.dispatch(editor.state.tr.setSelection(Selection.near(doc.resolve(caret))))
  }
  // After show()'s own scroll restore, which runs on the next frame.
  const mode = sourceMode
  const target = editor.state.doc
  requestAnimationFrame(() => requestAnimationFrame(() => {
    // Toggled again, or the document changed, in the meantime: leave it be.
    if (sourceMode !== mode || (!mode && editor.state.doc !== target)) return
    let y: number
    if (sourceMode) {
      y = sourceArea.getBoundingClientRect().top + textareaOffsetY(sourceArea, place.top)
    } else {
      const pos = docPosition(editor.state.doc, offsets, place.markdown, place.top)
      y = editor.view.coordsAtPos(pos).top
    }
    window.scrollBy(0, y - TOP_MARGIN)
  }))
}

function autosizeSource() {
  sourceArea.style.height = 'auto'
  sourceArea.style.height = `${sourceArea.scrollHeight}px`
}
sourceArea.addEventListener('input', autosizeSource)

// ---------------------------------------------------------------------------
// Links and clicks

// ⌘-click opens links. Handled on mousedown (capture) so neither
// ProseMirror's selection handling nor WebKit's own link handling gets it first.
host.addEventListener(
  'mousedown',
  e => {
    const a = (e.target as HTMLElement).closest('a[href]') as HTMLAnchorElement | null
    if (a && e.metaKey && e.button === 0) {
      e.preventDefault()
      e.stopPropagation()
      post({ type: 'openLink', href: a.getAttribute('href') })
    }
  },
  true,
)

host.addEventListener('click', e => {
  const target = e.target as HTMLElement
  const a = target.closest('a[href]') as HTMLAnchorElement | null
  if (a) e.preventDefault()
  const ref = target.closest('sup[data-type="footnote-ref"]') as HTMLElement | null
  if (ref && e.metaKey) {
    const def = host.querySelector(`div[data-type="footnote-def"][data-label="${CSS.escape(ref.dataset.label ?? '')}"]`)
    def?.scrollIntoView({ block: 'center', behavior: 'smooth' })
  }
})
host.addEventListener('mouseover', e => {
  const a = (e.target as HTMLElement).closest('a[href]') as HTMLAnchorElement | null
  if (a && !a.title) a.title = `${a.getAttribute('href')}\n⌘-click to open`
})

// Clicking below the last line puts the caret at the end, like a text editor.
document.addEventListener('mousedown', e => {
  if (sourceMode || !activeId) return
  if (e.target === document.documentElement || e.target === document.body || (e.target as HTMLElement).id === 'page') {
    const rect = host.getBoundingClientRect()
    if (e.clientY > rect.bottom) {
      e.preventDefault()
      editor.commands.focus('end')
    }
  }
})

document.addEventListener('keydown', e => {
  if (e.key === 'Escape' && findBar.isOpen) findBar.close()
})

// Links show a hand cursor only while ⌘ is held, since ⌘-click opens them.
const setCmdHeld = (held: boolean) => document.body.classList.toggle('cmd-held', held)
document.addEventListener('keydown', e => setCmdHeld(e.metaKey))
document.addEventListener('keyup', e => setCmdHeld(e.metaKey))
document.addEventListener('mousemove', e => setCmdHeld(e.metaKey), { passive: true })
window.addEventListener('blur', () => setCmdHeld(false))

// ---------------------------------------------------------------------------
// API for native

const api = {
  /** Registers a document. `baseURL` is where relative images resolve (margin-file:///dir/). */
  open(id: string, markdown: string, baseURL = '', activate = true) {
    let doc = docs.get(id)
    if (!doc) {
      doc = { id, markdown, baseURL, state: null, scrollTop: 0, pending: false, source: null, sourceBase: null }
      docs.set(id, doc)
    }
    if (activate) api.activate(id)
  },

  activate(id: string) {
    const doc = docs.get(id)
    if (!doc || id === activeId) return
    stash()
    show(doc)
  },

  close(id: string) {
    const doc = docs.get(id)
    if (!doc) return
    if (doc.pending) flush()
    docs.delete(id)
    if (activeId === id) {
      activeId = null
      show(undefined)
    }
  },

  /** Native renamed/moved the file. */
  rename(oldId: string, newId: string, baseURL: string) {
    const doc = docs.get(oldId)
    if (!doc) return
    docs.delete(oldId)
    doc.id = newId
    doc.baseURL = baseURL
    docs.set(newId, doc)
    if (activeId === oldId) {
      activeId = newId
      setImageBase(baseURL)
    }
  },

  /** The file changed on disk and the tab has no unsaved edits. */
  /**
   * The file changed on disk (another app, Git, an AI agent) and the tab has
   * no unsaved edits. Only the part that differs is replaced, so the caret,
   * selection, scroll position and undo history stay where they were.
   */
  reload(id: string, markdown: string) {
    const doc = docs.get(id)
    if (!doc) return
    if (currentMarkdown(doc) === markdown) {
      doc.markdown = markdown
      return
    }
    doc.markdown = markdown
    doc.pending = false

    if (doc.source !== null) {
      doc.source = doc.sourceBase = markdown
      doc.state = null
      if (id === activeId && sourceMode) {
        const { selectionStart, selectionEnd } = sourceArea
        const top = document.scrollingElement!.scrollTop
        sourceArea.value = markdown
        autosizeSource()
        sourceArea.setSelectionRange(Math.min(selectionStart, markdown.length), Math.min(selectionEnd, markdown.length))
        document.scrollingElement!.scrollTop = top
      }
      return
    }
    if (!doc.state && id !== activeId) return // parsed lazily from doc.markdown

    const state = id === activeId ? editor.state : doc.state!
    const tr = patch(state, buildDoc(markdown))
    if (!tr) return
    if (id === activeId) {
      const top = document.scrollingElement!.scrollTop
      editor.view.dispatch(tr)
      document.scrollingElement!.scrollTop = top
    } else {
      doc.state = state.apply(tr)
    }
  },

  getMarkdown(id: string): string | null {
    const doc = docs.get(id)
    if (!doc) return null
    if (doc.id === activeId) stash()
    return currentMarkdown(doc)
  },

  flush,

  command(name: string, args?: any) {
    if (!activeId) return false
    if (sourceMode) return false
    return runCommand(editor, name, args)
  },

  setSourceMode(on: boolean) {
    if (on === sourceMode) return
    const doc = active()
    // Where you are — the caret and the first line on screen — as Markdown
    // offsets, so the other view can open at the same place.
    const place = doc ? placeInMarkdown() : null
    stash()
    if (on && doc) doc.source = doc.sourceBase = place?.markdown ?? currentMarkdown(doc)
    sourceMode = on
    document.body.classList.toggle('source-mode', on)
    findBar.close()
    if (doc) {
      activeId = null
      show(doc)
    }
    if (on) sourceArea.focus({ preventScroll: true })
    else editor.view.focus()
    if (place) goToPlace(place)
    scheduleState()
  },

  find(mode: 'open' | 'replace' | 'next' | 'previous') {
    if (sourceMode) return
    if (mode === 'open') findBar.open()
    else if (mode === 'replace') findBar.open(true)
    else if (mode === 'next') findBar.next()
    else findBar.previous()
  },

  settings(s: { fontSize?: number; width?: number; font?: 'sans' | 'serif' | 'mono'; accent?: string; rail?: boolean }) {
    const root = document.documentElement.style
    if (s.rail !== undefined) rail.enabled = s.rail
    if (s.fontSize) root.setProperty('--font-size', `${s.fontSize}px`)
    if (s.width) root.setProperty('--content-width', `${s.width}px`)
    if (s.accent) root.setProperty('--accent', s.accent)
    if (s.font) {
      const stacks = {
        sans: 'var(--font-text)',
        serif: 'ui-serif, "New York", "Songti SC", Georgia, serif',
        mono: 'var(--font-mono)',
      }
      root.setProperty('--font-body', stacks[s.font] ?? stacks.sans)
    }
    requestAnimationFrame(() => rail.rebuild())
  },

  /** Scrolls to the n-th heading of the outline and puts the caret there. */
  goToHeading(index: number) {
    if (sourceMode) {
      const re = /^#{1,6}\s+.+$/gm
      let m, i = 0
      while ((m = re.exec(sourceArea.value))) {
        if (i++ === index) {
          sourceArea.focus()
          sourceArea.setSelectionRange(m.index, m.index)
          const before = sourceArea.value.slice(0, m.index).split('\n').length - 1
          const line = parseFloat(getComputedStyle(sourceArea).lineHeight) || 24
          window.scrollTo({ top: sourceArea.offsetTop + before * line - 80, behavior: 'smooth' })
          return
        }
      }
      return
    }
    let found = -1
    let i = 0
    editor.state.doc.descendants((node, pos) => {
      if (found >= 0) return false
      if (node.type.name === 'heading') {
        if (i++ === index) found = pos
      }
      return node.isBlock && node.type.name !== 'heading'
    })
    if (found < 0) return
    editor.chain().focus().setTextSelection(found + 1).run()
    const dom = editor.view.nodeDOM(found) as HTMLElement | null
    if (dom) window.scrollTo({ top: dom.getBoundingClientRect().top + window.scrollY - 24, behavior: 'smooth' })
  },

  focus() {
    if (sourceMode) sourceArea.focus()
    else editor.commands.focus()
  },

  /** Opens the find bar with `query` (used by project search results). */
  reveal(query: string) {
    if (sourceMode) {
      const i = sourceArea.value.toLowerCase().indexOf(query.toLowerCase())
      if (i >= 0) {
        sourceArea.focus()
        sourceArea.setSelectionRange(i, i + query.length)
      }
      return
    }
    findBar.open(false, query)
  },

  /** The active document as a standalone HTML page body (rendered math, diagrams). */
  async exportHTML(): Promise<{ title: string; body: string } | null> {
    if (!activeId) return null
    // Export must wait for the actual render, even on a cold or slow page.
    await Promise.all(Array.from(host.querySelectorAll('.code-block.is-mermaid')).map(async block => {
      const preview = block.querySelector('.diagram')!
      try {
        preview.innerHTML = await renderMermaid(block.querySelector('code')?.textContent ?? '')
      } catch (error) {
        preview.textContent = String(error)
      }
    }))
    await document.fonts?.ready
    // A remote image may never respond. Bound only that wait; local images
    // normally decode immediately and failed images don't block export.
    let imageTimeout: number | undefined
    await Promise.race([
      Promise.all(Array.from(host.querySelectorAll('img')).map(img => img.decode?.().catch(() => {}))),
      new Promise(resolve => { imageTimeout = window.setTimeout(resolve, 5000) }),
    ])
    clearTimeout(imageTimeout)
    const clone = host.querySelector('.ProseMirror')!.cloneNode(true) as HTMLElement
    clone.querySelectorAll('.code-header, .ProseMirror-separator, .ProseMirror-trailingBreak, .ProseMirror-gapcursor').forEach(n => n.remove())
    clone.querySelectorAll('[contenteditable]').forEach(n => n.removeAttribute('contenteditable'))
    clone.querySelectorAll('img[data-src]').forEach(img => {
      img.setAttribute('src', img.getAttribute('data-src')!)
      img.removeAttribute('data-src')
    })
    clone.querySelectorAll('.code-block.is-mermaid pre').forEach(n => n.remove())
    clone.querySelectorAll('.code-block:not(.is-mermaid) .diagram').forEach(n => n.remove())
    clone.querySelectorAll('[data-placeholder]').forEach(n => {
      n.removeAttribute('data-placeholder')
      n.classList.remove('is-empty', 'is-editor-empty')
      if (!n.className) n.removeAttribute('class')
    })
    clone.querySelectorAll('.find-match').forEach(n => n.replaceWith(...Array.from(n.childNodes)))
    clone.removeAttribute('contenteditable')
    clone.removeAttribute('translate')
    clone.removeAttribute('tabindex')
    clone.removeAttribute('role')
    const title = (clone.querySelector('h1, h2, h3')?.textContent ?? '').trim()
    return { title, body: clone.outerHTML }
  },

  /** Test hook: parse + serialize without touching any document. */
  roundTrip(markdown: string) {
    return serializeMarkdown(editor, parseMarkdown(editor, markdown))
  },
}

window.margin = Object.assign(api, { post })
show(undefined)
post({ type: 'ready' })
