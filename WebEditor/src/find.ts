// Find & replace: a ProseMirror plugin that decorates matches, plus the
// floating find bar UI.
import { Extension, type Editor } from '@tiptap/core'
import { Plugin, PluginKey, TextSelection, type EditorState } from '@tiptap/pm/state'
import { Decoration, DecorationSet } from '@tiptap/pm/view'
import type { Node as PMNode } from '@tiptap/pm/model'

interface FindState {
  query: string
  matches: { from: number; to: number }[]
  index: number
  decorations: DecorationSet
}

const key = new PluginKey<FindState>('find')

function search(doc: PMNode, query: string) {
  const matches: { from: number; to: number }[] = []
  if (!query) return matches
  // Match against the original string: lowercasing can change its length
  // (e.g. İ -> i + combining dot), invalidating ProseMirror positions.
  const pattern = new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'giu')
  doc.descendants((node, pos) => {
    if (!node.isTextblock) return true
    // Collect the textblock's text with a position map (inline atoms count as one char).
    let text = ''
    const positions: number[] = []
    node.forEach((child, offset) => {
      if (child.isText) {
        for (let i = 0; i < child.text!.length; i++) {
          text += child.text![i]
          positions.push(pos + 1 + offset + i)
        }
      } else {
        text += '￼'
        positions.push(pos + 1 + offset)
      }
    })
    for (const match of text.matchAll(pattern)) {
      const i = match.index!
      matches.push({ from: positions[i], to: positions[i + match[0].length - 1] + 1 })
    }
    return false
  })
  return matches
}

function build(doc: PMNode, query: string, index: number): FindState {
  const matches = search(doc, query)
  const clamped = matches.length ? Math.min(Math.max(index, 0), matches.length - 1) : -1
  const decorations = DecorationSet.create(
    doc,
    matches.map((m, i) => Decoration.inline(m.from, m.to, { class: i === clamped ? 'find-match current' : 'find-match' })),
  )
  return { query, matches, index: clamped, decorations }
}

export const Find = Extension.create({
  name: 'find',
  addProseMirrorPlugins() {
    return [
      new Plugin<FindState>({
        key,
        state: {
          init: () => ({ query: '', matches: [], index: -1, decorations: DecorationSet.empty }),
          apply(tr, prev) {
            const meta = tr.getMeta(key) as { query?: string; index?: number } | undefined
            if (meta) return build(tr.doc, meta.query ?? prev.query, meta.index ?? prev.index)
            if (tr.docChanged && prev.query) return build(tr.doc, prev.query, prev.index)
            return prev
          },
        },
        props: {
          decorations: state => key.getState(state)?.decorations,
        },
      }),
    ]
  },
})

export function findState(state: EditorState) {
  return key.getState(state)
}

// ---------------------------------------------------------------------------
// Find bar

export class FindBar {
  private el: HTMLElement
  private input: HTMLInputElement
  private replaceInput: HTMLInputElement
  private count: HTMLElement
  private replaceRow: HTMLElement

  constructor(private getEditor: () => Editor) {
    this.el = document.createElement('div')
    this.el.className = 'find-bar'
    this.el.hidden = true
    this.el.innerHTML = `
      <div class="find-row">
        <input class="find-input" placeholder="Find" spellcheck="false">
        <span class="find-count"></span>
        <button data-act="prev" title="Previous (⇧⌘G)"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="m18 15-6-6-6 6"/></svg></button>
        <button data-act="next" title="Next (⌘G)"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="m6 9 6 6 6-6"/></svg></button>
        <button data-act="toggle-replace" title="Replace">⇄</button>
        <button data-act="close" title="Close (esc)">✕</button>
      </div>
      <div class="find-row replace-row" hidden>
        <input class="replace-input" placeholder="Replace" spellcheck="false">
        <button data-act="replace">Replace</button>
        <button data-act="replace-all">All</button>
      </div>`
    document.body.appendChild(this.el)
    this.input = this.el.querySelector('.find-input')!
    this.replaceInput = this.el.querySelector('.replace-input')!
    this.count = this.el.querySelector('.find-count')!
    this.replaceRow = this.el.querySelector('.replace-row')!

    this.input.addEventListener('input', () => this.setQuery(this.input.value, 0))
    this.el.addEventListener('keydown', e => {
      if (e.key === 'Escape') {
        e.preventDefault()
        this.close()
      } else if (e.key === 'Enter' && e.target === this.input) {
        e.preventDefault()
        e.shiftKey ? this.previous() : this.next()
      } else if (e.key === 'Enter' && e.target === this.replaceInput) {
        e.preventDefault()
        this.replace()
      } else if (e.key === 'g' && e.metaKey) {
        e.preventDefault()
        e.shiftKey ? this.previous() : this.next()
      }
      e.stopPropagation()
    })
    this.el.addEventListener('click', e => {
      const act = (e.target as HTMLElement).closest('button')?.dataset.act
      if (act === 'prev') this.previous()
      else if (act === 'next') this.next()
      else if (act === 'close') this.close()
      else if (act === 'toggle-replace') this.replaceRow.hidden = !this.replaceRow.hidden
      else if (act === 'replace') this.replace()
      else if (act === 'replace-all') this.replaceAll()
    })
  }

  get isOpen() {
    return !this.el.hidden
  }

  open(withReplace = false, query?: string) {
    const editor = this.getEditor()
    const { from, to } = editor.state.selection
    const selected = from !== to ? editor.state.doc.textBetween(from, to, ' ') : ''
    if (query !== undefined) this.input.value = query
    else if (selected && !selected.includes('\n')) this.input.value = selected
    this.el.hidden = false
    if (withReplace) this.replaceRow.hidden = false
    this.setQuery(this.input.value, 0)
    this.input.focus()
    this.input.select()
  }

  close() {
    if (this.el.hidden) return
    this.el.hidden = true
    this.dispatch({ query: '', index: -1 })
    this.getEditor().commands.focus()
  }

  /** Re-run the search after the editor swapped documents. */
  refresh() {
    if (this.isOpen) this.setQuery(this.input.value, 0)
  }

  next() {
    this.step(1)
  }

  previous() {
    this.step(-1)
  }

  private step(delta: number) {
    if (this.el.hidden) return this.open()
    const s = findState(this.getEditor().state)
    if (!s || !s.matches.length) return
    const index = (s.index + delta + s.matches.length) % s.matches.length
    this.dispatch({ index })
    this.reveal()
  }

  private setQuery(query: string, index: number) {
    this.dispatch({ query, index })
    this.reveal()
  }

  private dispatch(meta: { query?: string; index?: number }) {
    const editor = this.getEditor()
    editor.view.dispatch(editor.state.tr.setMeta(key, meta).setMeta('addToHistory', false))
    this.updateCount()
  }

  private updateCount() {
    const s = findState(this.getEditor().state)
    if (!s || !s.query) this.count.textContent = ''
    else if (!s.matches.length) this.count.textContent = 'No results'
    else this.count.textContent = `${s.index + 1} of ${s.matches.length}`
    this.el.classList.toggle('no-results', !!s?.query && !s.matches.length)
  }

  private reveal() {
    const editor = this.getEditor()
    const s = findState(editor.state)
    if (!s || s.index < 0) return
    const m = s.matches[s.index]
    const tr = editor.state.tr.setSelection(TextSelection.create(editor.state.doc, m.from, m.to))
    editor.view.dispatch(tr.scrollIntoView())
    const dom = editor.view.domAtPos(m.from).node as HTMLElement
    const el = dom.nodeType === 1 ? dom : dom.parentElement
    el?.scrollIntoView({ block: 'center' })
  }

  private replace() {
    const editor = this.getEditor()
    const s = findState(editor.state)
    if (!s || s.index < 0) return
    const m = s.matches[s.index]
    const text = this.replaceInput.value
    const tr = editor.state.tr
    if (text) tr.insertText(text, m.from, m.to)
    else tr.delete(m.from, m.to)
    editor.view.dispatch(tr)
    this.dispatch({ index: s.index })
    this.reveal()
  }

  private replaceAll() {
    const editor = this.getEditor()
    const s = findState(editor.state)
    if (!s || !s.matches.length) return
    const text = this.replaceInput.value
    const tr = editor.state.tr
    for (const m of [...s.matches].reverse()) {
      if (text) tr.insertText(text, m.from, m.to)
      else tr.delete(m.from, m.to)
    }
    editor.view.dispatch(tr)
    this.updateCount()
  }
}
