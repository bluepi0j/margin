// Gives node a DOM so TipTap can run, then loads the bundled editor core.
import { Window } from 'happy-dom'

const win = new Window({ url: 'http://localhost/' })
win.document.write('<!doctype html><html><body></body></html>')
for (const key of ['window', 'document', 'navigator', 'Node', 'HTMLElement', 'Element', 'DOMParser', 'getComputedStyle', 'MutationObserver', 'requestAnimationFrame', 'cancelAnimationFrame', 'DOMRect', 'Text', 'DocumentFragment', 'KeyboardEvent']) {
  if (!(key in globalThis) || key === 'window' || key === 'document' || key === 'navigator') {
    try { Object.defineProperty(globalThis, key, { value: win[key], configurable: true, writable: true }) } catch {}
  }
}

export const core = await import('./.build/core.mjs')

export function makeEditor() {
  const el = document.createElement('div')
  document.body.appendChild(el)
  return core.createEditor(el)
}

export function roundTrip(editor, md) {
  return core.serializeMarkdown(editor, core.parseMarkdown(editor, md))
}
