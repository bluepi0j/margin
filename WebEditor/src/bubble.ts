// A small glass bar above selected text with the inline formats, so you
// don't have to travel to the toolbar.
import type { Editor } from '@tiptap/core'
import { NodeSelection } from '@tiptap/pm/state'
import { runCommand } from './editor'
import { isPopoverOpen } from './popover'

// Stroke icons, 24×24 grid (after Lucide, ISC licence).
const ICONS: Record<string, string> = {
  bold: '<path d="M6 4h7a4 4 0 0 1 0 8H6z"/><path d="M6 12h8a4 4 0 0 1 0 8H6z"/>',
  italic: '<path d="M19 4h-9"/><path d="M14 20H5"/><path d="M15 4 9 20"/>',
  strike: '<path d="M16 4H9a3 3 0 0 0-2.83 4"/><path d="M14 12a4 4 0 0 1 0 8H6"/><path d="M4 12h16"/>',
  code: '<path d="m16 18 6-6-6-6"/><path d="m8 6-6 6 6 6"/>',
  highlight: '<path d="m9 11-6 6v3h9l3-3"/><path d="m22 12-4.6 4.6a2 2 0 0 1-2.8 0l-5.2-5.2a2 2 0 0 1 0-2.8L14 4"/>',
  link: '<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>',
}

const BUTTONS: [string, string][] = [
  ['bold', 'Bold ⌘B'],
  ['italic', 'Italic ⌘I'],
  ['strike', 'Strikethrough ⇧⌘X'],
  ['code', 'Inline code ⌘E'],
  ['highlight', 'Highlight ⇧⌘E'],
  ['link', 'Link ⌘K'],
]

export class BubbleBar {
  private el = document.createElement('div')
  private dragging = false

  constructor(private editor: Editor) {
    this.el.className = 'bubble'
    this.el.hidden = true
    for (const [cmd, title] of BUTTONS) {
      const b = document.createElement('button')
      b.dataset.cmd = cmd
      b.title = title
      b.innerHTML = `<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round">${ICONS[cmd]}</svg>`
      this.el.appendChild(b)
    }
    // Act on mousedown, like the editor's own controls: WebKit can deliver the
    // first press on a freshly shown bar out of order, and then no click fires.
    this.el.addEventListener('mousedown', e => {
      e.preventDefault()
      const cmd = (e.target as Element).closest('button')?.dataset.cmd
      if (!cmd || e.button !== 0) return
      runCommand(this.editor, cmd)
      if (cmd === 'link') this.hide()
      else this.update()
    })
    document.body.appendChild(this.el)

    // Wait for the mouse to come up before showing, so it doesn't jump around mid-drag.
    // A double/triple click selects the word/paragraph right away and isn't a
    // drag (WebKit may not even deliver its mouseup to the page).
    editor.view.dom.addEventListener('mousedown', e => {
      this.dragging = e.detail < 2
      this.hide()
      if (!this.dragging) setTimeout(() => this.update(), 30)
    })
    const endDrag = () => {
      if (!this.dragging) return
      this.dragging = false
      requestAnimationFrame(() => this.update())
    }
    document.addEventListener('mouseup', endDrag)
    // Safety net for a lost mouseup: the button is up as soon as the mouse moves.
    document.addEventListener('mousemove', e => {
      if (this.dragging && e.buttons === 0) endDrag()
    })
    window.addEventListener('scroll', () => this.update(), { passive: true })
  }

  hide() {
    this.el.hidden = true
  }

  update() {
    const { editor } = this
    const sel = editor.state.selection
    const show =
      !this.dragging &&
      editor.isEditable &&
      editor.view.hasFocus() &&
      // Text or select-all; not a selected image/formula node.
      !(sel instanceof NodeSelection) &&
      !sel.empty &&
      !editor.isActive('codeBlock') &&
      !isPopoverOpen() &&
      !document.body.classList.contains('source-mode')
    if (!show) return this.hide()

    for (const b of this.el.querySelectorAll('button')) {
      b.classList.toggle('active', editor.isActive(b.dataset.cmd === 'strike' ? 'strike' : b.dataset.cmd!))
    }
    // The browser's own selection box is the most reliable anchor (it also
    // handles select-all, whose start is outside any text).
    const domSel = window.getSelection()
    let box = domSel && domSel.rangeCount ? domSel.getRangeAt(0).getBoundingClientRect() : null
    if (!box || (box.width === 0 && box.height === 0)) {
      const a = editor.view.coordsAtPos(Math.max(1, sel.from))
      const b = editor.view.coordsAtPos(sel.to, -1)
      box = new DOMRect(a.left, Math.min(a.top, b.top), Math.max(1, b.right - a.left), Math.max(a.bottom, b.bottom) - Math.min(a.top, b.top))
    }
    this.el.hidden = false
    const w = this.el.offsetWidth
    const h = this.el.offsetHeight
    const singleLine = box.height < 40
    const center = singleLine ? box.left + box.width / 2 : box.left + w / 2
    const left = Math.max(8, Math.min(center - w / 2, window.innerWidth - w - 8))
    let top = box.top - h - 8
    if (top < 8) top = box.bottom + 8
    this.el.style.left = `${left}px`
    this.el.style.top = `${top}px`
  }
}
