// The page API native calls: tabs as separate documents, edits reported
// back, source mode, external reloads.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import './setup.mjs'

document.body.innerHTML = `<div id="page"><div id="editor"></div><textarea id="source" hidden></textarea></div><div id="empty"></div><div id="word-count"></div>`
const messages = []
window.webkit = { messageHandlers: { margin: { postMessage: m => messages.push(m) } } }
globalThis.CSS ??= { escape: s => s }
await import('./.build/page.mjs')
const margin = window.margin
const editor = () => document.querySelector('.ProseMirror').editor

function typeText(text) {
  const view = editor().view
  const { from, to } = view.state.selection
  view.dispatch(view.state.tr.insertText(text, from, to))
}

test('page reports ready', () => {
  assert.ok(messages.some(m => m.type === 'ready'))
})

test('heading level zero turns a heading into a paragraph', () => {
  margin.open('paragraph', '## Heading\n', '', true)
  margin.command('heading', { level: 0 })
  assert.equal(margin.getMarkdown('paragraph'), 'Heading\n')
  margin.close('paragraph')
})

test('export waits for the diagram renderer before returning HTML', async () => {
  window.MarginMermaid = { render: () => '<svg data-test="rendered"></svg>' }
  margin.open('export-diagram', '# Export\n\n```mermaid\ngraph LR\nA --> B\n```\n', '', true)
  const result = await margin.exportHTML()
  assert.equal(result.title, 'Export')
  assert.match(result.body, /data-test="rendered"/)
  assert.doesNotMatch(result.body, /code-header|<pre/)
  margin.close('export-diagram')
  delete window.MarginMermaid
})

test('find and replace keeps positions after Unicode case expansion', () => {
  margin.open('unicode-find', 'İstanbul next NEXT\n', '', true)
  margin.find('replace')
  const input = document.querySelector('.find-input')
  input.value = 'next'
  input.dispatchEvent(new window.Event('input'))
  document.querySelector('.replace-input').value = 'done'
  document.querySelector('[data-act="replace-all"]').click()
  assert.equal(margin.getMarkdown('unicode-find'), 'İstanbul done done\n')
  margin.find('open')
  document.querySelector('[data-act="close"]').click()
  margin.close('unicode-find')
})

test('each tab keeps its own document', () => {
  margin.open('a', '# A\n', '', true)
  margin.open('b', '# B\n', '', true)
  assert.equal(margin.getMarkdown('a'), '# A\n')
  assert.equal(margin.getMarkdown('b'), '# B\n')
  assert.match(document.querySelector('.ProseMirror').textContent, /^B/)
  margin.activate('a')
  assert.match(document.querySelector('.ProseMirror').textContent, /^A/)
})

test('edits are reported once, then flushed as content', () => {
  messages.length = 0
  margin.activate('a')
  editor().commands.focus('end')
  typeText(' more')
  assert.deepEqual(messages.filter(m => m.type === 'edited').map(m => m.id), ['a'])
  const flushed = margin.flush()
  assert.equal(flushed.a, '# A more\n')
  assert.ok(messages.some(m => m.type === 'content' && m.id === 'a' && m.markdown === '# A more\n'))
  assert.deepEqual(margin.flush(), {}, 'nothing pending after a flush')
})

test('undo history stays with its tab', () => {
  margin.activate('b')
  margin.activate('a')
  editor().commands.undo()
  assert.equal(margin.getMarkdown('a'), '# A\n')
  assert.equal(margin.getMarkdown('b'), '# B\n')
})

test('switching tabs does not report edits', () => {
  margin.flush()
  messages.length = 0
  margin.activate('b')
  margin.activate('a')
  assert.equal(messages.filter(m => m.type === 'edited' || m.type === 'content').length, 0)
})

test('external reload replaces content without marking it edited', () => {
  messages.length = 0
  margin.reload('a', '# A from disk\n')
  assert.equal(margin.getMarkdown('a'), '# A from disk\n')
  assert.equal(messages.filter(m => m.type === 'edited').length, 0)
  margin.reload('b', '# B from disk\n')
  margin.activate('b')
  assert.match(document.querySelector('.ProseMirror').textContent, /B from disk/)
})

test('external change keeps the caret where it was', () => {
  margin.open('agent', '# Title\n\nFirst paragraph.\n\nSecond paragraph.\n', '', true)
  // Caret inside "Second" (well after the part that will change).
  const ed = editor()
  let pos = 0
  ed.state.doc.forEach((n, off, i) => { if (i === 2) pos = off + 4 })
  ed.commands.setTextSelection(pos)
  const textAfter = ed.state.doc.textBetween(pos, pos + 6)
  margin.reload('agent', '# Title\n\nFirst paragraph, edited by an agent.\n\nSecond paragraph.\n')
  const now = ed.state.selection.from
  assert.equal(ed.state.doc.textBetween(now, now + 6), textAfter)
  assert.equal(margin.getMarkdown('agent'), '# Title\n\nFirst paragraph, edited by an agent.\n\nSecond paragraph.\n')
  // Undo history from before the reload is still there and the reload itself is not undoable.
  assert.equal(messages.filter(m => m.type === 'edited' && m.id === 'agent').length, 0)
})

test('external change to a background tab keeps its state', () => {
  margin.open('bg', 'one\n\ntwo\n', '', true)
  margin.activate('agent')
  margin.reload('bg', 'one\n\ntwo\n\nthree\n')
  assert.equal(margin.getMarkdown('bg'), 'one\n\ntwo\n\nthree\n')
  margin.activate('bg')
  assert.match(document.querySelector('.ProseMirror').textContent, /three/)
  margin.close('agent')
  margin.close('bg')
})

test('source mode shows and edits raw Markdown', () => {
  margin.activate('a')
  margin.setSourceMode(true)
  const area = document.getElementById('source')
  assert.equal(area.hidden, false)
  assert.equal(area.value, '# A from disk\n')
  area.value = '## Changed in source\n'
  area.dispatchEvent(new window.Event('input'))
  assert.equal(margin.flush().a, '## Changed in source\n')
  margin.setSourceMode(false)
  assert.equal(area.hidden, true)
  assert.equal(margin.getMarkdown('a'), '## Changed in source\n')
  assert.equal(document.querySelector('.ProseMirror h2')?.textContent, 'Changed in source')
})

test('Enter works in a document with a standalone image', () => {
  margin.open('img', 'para\n\n![Logo](a.png)\n', '', true)
  editor().commands.setTextSelection(5)
  editor().commands.keyboardShortcut('Enter')
  assert.equal(editor().state.doc.childCount, 3)
  margin.close('img')
})

test('closing the active tab leaves an empty page', () => {
  margin.close('a')
  margin.close('b')
  assert.equal(document.getElementById('editor').hidden, true)
  assert.equal(margin.getMarkdown('a'), null)
})

test('commands are ignored with no document', () => {
  assert.equal(margin.command('bold'), false)
})

test('Edit on a diagram opens its source and keeps it open', async () => {
  margin.open('diagram', 'Intro\n\n```mermaid\ngraph LR\n  A --> B\n```\n', '', true)
  const block = document.querySelector('.code-block.is-mermaid')
  const toggle = block.querySelector('.code-toggle')
  toggle.dispatchEvent(new window.MouseEvent('mousedown', { button: 0, bubbles: true, cancelable: true }))
  // ProseMirror's DOM observer runs asynchronously; give it the chance to
  // (wrongly) redraw the block before checking.
  await new Promise(r => setTimeout(r, 50))
  assert.ok(block.isConnected, 'the block was not redrawn')
  assert.ok(block.classList.contains('editing'))
  assert.equal(toggle.textContent, 'Done')
  assert.equal(editor().state.selection.$from.parent.type.name, 'codeBlock', 'caret is in the source')

  toggle.dispatchEvent(new window.MouseEvent('mousedown', { button: 0, bubbles: true, cancelable: true }))
  await new Promise(r => setTimeout(r, 50))
  assert.ok(!block.classList.contains('editing'))
  assert.equal(toggle.textContent, 'Edit')
})
