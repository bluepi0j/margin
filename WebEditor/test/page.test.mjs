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

test('word count: punctuation on its own is not a word', async () => {
  const { countWords } = await import('./.build/page.mjs')
  assert.equal(countWords("Hello, world! It's well-known."), 4)
  assert.equal(countWords('a - b -- c'), 3)
  assert.equal(countWords('- one\n- two\n\n---\n'), 2)
  assert.equal(countWords('中文字数 test'), 5)
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

test('a search result opens at the match on its line', () => {
  margin.open('reveal-line', '# Notes\n\nfirst target here\n\n- item\n- another target\n\nlast target\n', '', true)
  const shown = () => {
    const { state } = editor()
    assert.equal(state.doc.textBetween(state.selection.from, state.selection.to), 'target')
    return state.selection.$from.parent.textContent
  }
  margin.reveal('target', 6)
  assert.equal(shown(), 'another target')
  margin.reveal('target', 8)
  assert.equal(shown(), 'last target')
  margin.reveal('target', 3)
  assert.equal(shown(), 'first target here')
  // Nothing from that line on (the file changed since the search): the first match.
  margin.reveal('target', 40)
  assert.equal(shown(), 'first target here')
  // Source mode searches the text itself from that line.
  margin.setSourceMode(true)
  margin.reveal('TARGET', 6)
  const source = document.getElementById('source')
  assert.equal(source.value.slice(0, source.selectionStart).split('\n').length, 6)
  margin.setSourceMode(false)
  document.querySelector('[data-act="close"]').click()
  margin.close('reveal-line')
})

test('command-F opens the page find bar before WebKit handles it', () => {
  margin.open('keyboard-find', 'Alpha beta\n', '', true)
  const event = new window.KeyboardEvent('keydown', {
    key: 'f', metaKey: true, bubbles: true, cancelable: true,
  })
  document.dispatchEvent(event)
  assert.equal(event.defaultPrevented, true)
  assert.equal(document.querySelector('.find-bar').hidden, false)
  document.dispatchEvent(new window.KeyboardEvent('keydown', {
    key: 'Escape', bubbles: true, cancelable: true,
  }))
  assert.equal(document.querySelector('.find-bar').hidden, true)
  margin.close('keyboard-find')
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

test('outline rail keeps its current-section marker after rebuilding at the same position', () => {
  margin.open('rail-rebuild', '# First\n\n## Second\n\n## Third\n', '', true)
  const page = document.getElementById('editor')
  const original = page.getBoundingClientRect
  page.getBoundingClientRect = () => ({ left: 100, top: 0, width: 760, height: 900 })
  try {
    window.dispatchEvent(new window.Event('resize'))
    assert.equal(document.querySelector('.rail').hidden, false)
    assert.equal(document.querySelectorAll('.rail-tick.is-active').length, 1)
    window.dispatchEvent(new window.Event('resize'))
    assert.equal(document.querySelectorAll('.rail-tick.is-active').length, 1)
  } finally {
    page.getBoundingClientRect = original
    margin.close('rail-rebuild')
  }
})

test('changes since the last commit follow tabs and source mode', async () => {
  const changes = () => messages.filter(m => m.type === 'changes')
  margin.open('diff-a', '# A\n\nNew text.\n', '', true)
  margin.setDiffBase('diff-a', '# A\n\nOld text.\n')
  assert.deepEqual(changes().at(-1), { type: 'changes', id: 'diff-a', count: 1 })
  assert.equal(document.querySelectorAll('.diff-added').length, 1)
  assert.equal(document.querySelectorAll('.diff-ghost').length, 1)

  // Another tab without a base: no marks, and "not showing" (-1) for it.
  margin.open('diff-b', 'Plain\n', '', true)
  assert.deepEqual(changes().at(-1), { type: 'changes', id: 'diff-b', count: -1 })
  assert.equal(document.querySelectorAll('.diff-added, .diff-ghost').length, 0)

  // Back: the marks come back with the tab; the base can be set while hidden.
  margin.setDiffBase('diff-b', 'Plain\n\nRemoved.\n')
  margin.activate('diff-a')
  assert.deepEqual(changes().at(-1), { type: 'changes', id: 'diff-a', count: 1 })
  assert.equal(document.querySelectorAll('.diff-added').length, 1)
  margin.activate('diff-b')
  assert.deepEqual(changes().at(-1), { type: 'changes', id: 'diff-b', count: 1 })
  assert.equal(document.querySelectorAll('.diff-ghost').length, 1)

  // Source mode shows plain text: no count while it's on.
  margin.setSourceMode(true)
  assert.equal(changes().at(-1).count, -1)
  margin.setSourceMode(false)
  assert.equal(changes().at(-1).count, 1)

  // Restoring saves like any other edit; the decorations never reach the Markdown.
  document.querySelector('.diff-restore').dispatchEvent(new window.MouseEvent('click', { bubbles: true }))
  assert.equal(margin.getMarkdown('diff-b'), 'Plain\n\nRemoved.\n')
  assert.equal(changes().at(-1).count, 0)

  margin.setDiffBase('diff-b', null)
  assert.equal(changes().at(-1).count, -1)
  assert.equal(document.querySelectorAll('.diff-restore').length, 0)
  margin.close('diff-a')
  margin.close('diff-b')
})

test('export leaves out the changes since the last commit', async () => {
  margin.open('diff-export', '# Title\n\nThe new words.\n', '', true)
  margin.setDiffBase('diff-export', '# Title\n\nThe old words.\n\n## Gone\n')
  assert.ok(document.querySelector('.diff-ghost'))
  const result = await margin.exportHTML()
  assert.doesNotMatch(result.body, /diff-|Gone|old words|↺/)
  assert.match(result.body, /The new words\./)
  margin.setDiffBase('diff-export', null)
  margin.close('diff-export')
})

test('the source box follows a new line width', async () => {
  margin.open('source-width', 'word '.repeat(400) + '\n', '', true)
  margin.setSourceMode(true)
  const area = document.querySelector('#source')
  area.style.height = '10px'
  margin.settings({ width: 500 })
  await new Promise(r => setTimeout(r, 50))
  // happy-dom has no layout, so scrollHeight is 0: the box was re-measured
  // when its explicit 10px height was replaced.
  assert.notEqual(area.style.height, '10px')
  margin.setSourceMode(false)
  margin.close('source-width')
})
