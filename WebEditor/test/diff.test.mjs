// Changes since the last commit: which blocks count as changed, the
// decorations that show them, and restoring a change.
import { test, afterEach } from 'node:test'
import assert from 'node:assert/strict'
import { makeEditor, core } from './setup.mjs'

// Editors left in the page slow every later DOM change down in happy-dom.
const made = []
function editorFor(doc) {
  const ed = makeEditor()
  made.push(ed)
  if (doc) ed.view.updateState(ed.state.constructor.create({ doc: doc(ed), plugins: ed.state.plugins }))
  return ed
}
afterEach(() => { for (const ed of made.splice(0)) { ed.view.dom.parentElement?.remove(); ed.destroy() } })

function docOf(editor, md) {
  return editor.schema.nodeFromJSON(core.parseMarkdown(editor, md))
}

function withDiff(base, current) {
  // A fresh state: the content isn't an undoable edit.
  const ed = editorFor(e => docOf(e, current))
  ed.view.dispatch(core.setDiffBase(ed.state.tr, docOf(ed, base)))
  return ed
}

const markdown = ed => core.serializeMarkdown(ed, ed.getJSON())

test('no changes, no hunks', () => {
  const md = '# Title\n\nSome text.\n\n- a\n- b\n'
  const ed = withDiff(md, md)
  assert.deepEqual(core.diffHunks(ed.state), [])
  assert.equal(ed.view.dom.querySelectorAll('.diff-added, .diff-ghost').length, 0)
})

test('added, removed and rewritten blocks are decorated', () => {
  const base = '# Title\n\nKeep this.\n\nThe quick brown fox.\n\nGone paragraph.\n\nEnd.\n'
  const current = '# Title\n\nKeep this.\n\nThe quick red fox.\n\nEnd.\n\nNew last line.\n'
  const ed = withDiff(base, current)
  const hunks = core.diffHunks(ed.state)
  // Rewritten sentence, removed paragraph, added line.
  assert.deepEqual(hunks.map(h => [h.old.length, h.added.length]), [[1, 1], [1, 0], [0, 1]])
  const dom = ed.view.dom
  assert.equal(dom.querySelectorAll('.diff-added').length, 2)
  assert.deepEqual([...dom.querySelectorAll('.diff-word-added')].map(e => e.textContent), ['red'])
  const ghosts = dom.querySelectorAll('.diff-ghost')
  assert.equal(ghosts.length, 2)
  assert.equal(ghosts[0].textContent, 'The quick brown fox.')
  assert.equal(ghosts[1].textContent, 'Gone paragraph.')
  assert.deepEqual([...ghosts[0].querySelectorAll('.diff-word-removed')].map(e => e.textContent), ['brown'])
  assert.equal(ghosts[0].getAttribute('contenteditable'), 'false')
  assert.equal(dom.querySelectorAll('.diff-restore').length, 3)
})

test('a changed list item is compared item by item', () => {
  const items = n => Array.from({ length: n }, (_, i) => `- item ${i}`).join('\n')
  const base = `Intro\n\n${items(8)}\n`
  const current = base.replace('- item 4', '- item four')
  const ed = withDiff(base, current)
  const hunks = core.diffHunks(ed.state)
  assert.equal(hunks.length, 1)
  assert.equal(hunks[0].list, 'bulletList')
  assert.equal(hunks[0].old.length, 1)
  assert.equal(ed.view.dom.querySelectorAll('li.diff-added').length, 1)
  assert.equal(ed.view.dom.querySelector('.diff-ghost li').textContent, 'item 4')
})

test('restoring every change gives back the committed document', () => {
  const cases = [
    ['# T\n\nA\n\nB\n\nC\n', '# T\n\nA changed\n\nC\n\nD\n'],
    ['A\n\nB\n\nC\n', 'A\n'],
    ['A\n\nB\n', 'Z\n\nA\n\nB\n'],
    ['Only\n', 'Different\n'],
    ['Base\n', 'Base\n\nAdded one\n\nAdded two\n'],
    ['- a\n- b\n- c\n', '- a\n- B!\n- c\n- d\n'],
    ['- [ ] one\n- [x] two\n', '- [x] one\n- [x] two\n- [ ] three\n'],
    ['A\n\nB\n\nC\n\nD\n', 'B\n\nA\n\nD\n\nC\n'],
    ['```js\nconst a = 1\n```\n\n| a | b |\n| - | - |\n| 1 | 2 |\n', '```js\nconst a = 2\n```\n\n| a | b |\n| - | - |\n| 1 | 3 |\n'],
  ]
  for (const [base, current] of cases) {
    const ed = withDiff(base, current)
    let guard = 20
    while (core.diffHunks(ed.state).length && guard--) {
      const tr = core.revertHunk(ed.state, core.diffHunks(ed.state).length - 1)
      ed.view.dispatch(tr)
    }
    assert.equal(markdown(ed), core.serializeMarkdown(ed, core.parseMarkdown(ed, base)), `${base} <- ${current}`)
    assert.deepEqual(core.diffHunks(ed.state), [])
  }
})

test('restoring one change keeps the others and can be undone', () => {
  const ed = withDiff('A\n\nB\n\nC\n', 'A1\n\nB\n\nC1\n')
  assert.equal(core.diffHunks(ed.state).length, 2)
  ed.view.dispatch(core.revertHunk(ed.state, 1))
  assert.equal(markdown(ed), 'A1\n\nB\n\nC\n')
  assert.equal(core.diffHunks(ed.state).length, 1)
  ed.commands.undo()
  assert.equal(markdown(ed), 'A1\n\nB\n\nC1\n')
})

test('the restore button restores its own change', () => {
  const ed = withDiff('A\n\nB\n\nC\n', 'A1\n\nB\n\nC1\n')
  const buttons = ed.view.dom.querySelectorAll('.diff-restore')
  assert.equal(buttons.length, 2)
  buttons[1].dispatchEvent(new window.MouseEvent('click', { bubbles: true }))
  assert.equal(markdown(ed), 'A1\n\nB\n\nC\n')
})

test('edits are re-diffed after a pause, and clearing the base removes the marks', async () => {
  const ed = withDiff('A\n\nB\n', 'A\n\nB\n')
  assert.equal(core.diffHunks(ed.state).length, 0)
  ed.view.dispatch(ed.state.tr.insertText(' more', ed.state.doc.child(0).nodeSize - 1))
  await new Promise(r => setTimeout(r, 300))
  assert.equal(core.diffHunks(ed.state).length, 1)
  assert.equal(ed.view.dom.querySelectorAll('.diff-added').length, 1)
  ed.view.dispatch(core.setDiffBase(ed.state.tr, null))
  assert.equal(ed.view.dom.querySelectorAll('.diff-added, .diff-ghost, .diff-restore').length, 0)
})

test('word diff', () => {
  const [removed, added] = core.wordDiff('The quick brown fox', 'The quick red fox')
  assert.deepEqual(removed, [[10, 15]])
  assert.deepEqual(added, [[10, 13]])
  // Chinese is compared by character.
  const [, cjk] = core.wordDiff('今天天气不错。', '今天天气很好。')
  assert.deepEqual(cjk.map(([s, e]) => '今天天气很好。'.slice(s, e)), ['很好'])
  // Unrelated text: no word marks.
  assert.deepEqual(core.wordDiff('alpha beta gamma', 'one two three'), [[], []])
})

test('a run of rewritten blocks splits into one change per rewrite', () => {
  const base = '# Goals\n\nThe quick brown fox jumps over the lazy dog.\n\nThis paragraph will be removed by the agent.\n\n- Fast startup\n- Native look\n- Plain files\n\n## Code\n'
  const current = '# Goals\n\nThe quick red fox leaps over the lazy dog.\n\nA brand new paragraph that the agent added here.\n\n- Fast startup\n- Native look and feel\n- Plain files\n\n## Code\n'
  const ed = withDiff(base, current)
  const hunks = core.diffHunks(ed.state)
  // The rewritten sentence, the replaced paragraph, the changed list item.
  assert.equal(hunks.length, 3)
  assert.deepEqual(hunks.map(h => [h.old.length, h.added.length]), [[1, 1], [1, 1], [1, 1]])
  assert.equal(hunks[2].list, 'bulletList')
  assert.deepEqual([...ed.view.dom.querySelectorAll('.diff-word-added')].map(e => e.textContent).slice(0, 2), ['red', 'leaps'])
  // Restoring the middle one leaves the others.
  ed.view.dispatch(core.revertHunk(ed.state, 1))
  assert.match(markdown(ed), /The quick red fox[^]*This paragraph will be removed by the agent\.[^]*Native look and feel/)
})
