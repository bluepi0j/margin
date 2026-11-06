// Diffing a big note stays fast. In its own file: in happy-dom, editors made
// earlier in the same process slow every later DOM update down a lot.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { makeEditor, core } from './setup.mjs'

const docOf = (editor, md) => editor.schema.nodeFromJSON(core.parseMarkdown(editor, md))
function editorFor(doc) {
  const ed = makeEditor()
  ed.view.updateState(ed.state.constructor.create({ doc: doc(ed), plugins: ed.state.plugins }))
  return ed
}

test('diffing a large document is fast', () => {
  const section = i => `## Section ${i}\n\n` + Array.from({ length: 10 }, (_, j) => `Paragraph ${j} of ${i}, with words.`).join('\n\n') + '\n\n'
  const base = Array.from({ length: 1000 }, (_, i) => section(i)).join('')
  const current = base.replace('## Section 500\n', '## Section 500 renamed\n') + 'Appended.\n'
  const ed = editorFor(e => docOf(e, current))
  const baseDoc = docOf(ed, base)
  const t = performance.now()
  ed.view.dispatch(core.setDiffBase(ed.state.tr, baseDoc))
  const first = performance.now() - t
  assert.equal(core.diffHunks(ed.state).length, 2)
  // Again after an edit: unchanged blocks are the same objects, keys are cached.
  ed.view.dispatch(ed.state.tr.insertText('x', 3))
  const t2 = performance.now()
  ed.view.dispatch(ed.state.tr.setMeta(ed.state.plugins.find(p => p.key.startsWith('gitDiff')).spec.key, { recompute: true }))
  const second = performance.now() - t2
  assert.ok(first < 2000, `first ${first.toFixed(0)} ms`)
  assert.ok(second < 300, `again ${second.toFixed(0)} ms`)
})
