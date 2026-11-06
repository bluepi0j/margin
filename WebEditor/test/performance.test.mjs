// Parsing and serializing must stay roughly linear in the document's size.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { makeEditor, core } from './setup.mjs'

const editor = makeEditor()

const sample = `# Title

Para with $x^2$ math, ==mark==, a footnote[^1] and **bold**.
Second line of the same paragraph | with a pipe.

| a | b |
| --- | --- |
| 1 | 2 |

$$
\\int_0^1 x\\,dx
$$

- [ ] todo
- [x] done
  - nested

> quote
> continues

<div>raw html</div>

[^1]: The note.
[^long]: Another
    note body.

Text right before a table
| h | i |
| - | - |
| 3 | 4 |
Text right before $$ inline-ish $$ math.

\`\`\`js
const a = '$$' // [^x]: not a footnote
\`\`\`
`

function withOriginalStarts(fn) {
  const ext = editor.markdown.markedInstance.defaults.extensions
  const bounded = ext.startBlock
  const blocks = ext.block
  const { index, tokenizer } = blocks.original
  const wrapped = blocks[index]
  ext.startBlock = bounded.original
  blocks[index] = tokenizer
  try { return fn() } finally { ext.startBlock = bounded; blocks[index] = wrapped }
}

test('bounded block starts parse exactly like the originals', () => {
  assert.ok(editor.markdown.markedInstance.defaults.extensions.startBlock.bounded)
  const tasks = `- [ ] one
  - [x] nested
    more nested text

- [ ] after a blank line
	indented with a tab
- plain bullet ends it
- [x] new list

  - [ ] indented start
text
`
  for (const md of [sample, sample.repeat(3), sample.replace(/\n\n/g, '\n'), tasks, tasks.replace(/\n/g, '\r\n')]) {
    const bounded = JSON.stringify(core.parseMarkdown(editor, md))
    const original = withOriginalStarts(() => JSON.stringify(core.parseMarkdown(editor, md)))
    assert.equal(bounded, original)
  }
})

test('parsing a long note is not quadratic', () => {
  const section = '## Section\n\n' + 'word '.repeat(60) + '\n\n- item\n- item\n\n'
  const time = md => { const t = performance.now(); core.parseMarkdown(editor, md); return performance.now() - t }
  time(section.repeat(50)) // warm up
  const small = time(section.repeat(400))
  const large = time(section.repeat(1600))
  // 4× the text: linear is ~4×, quadratic ~16×.
  assert.ok(large < small * 8, `400 sections ${small.toFixed(0)} ms, 1600 sections ${large.toFixed(0)} ms`)
})

test('code highlighting is incremental and follows edits', () => {
  const ed = makeEditor()
  ed.commands.setContent(core.parseMarkdown(ed, 'Intro\n\n```js\nconst a = 1\n```\n\n- item\n\n  ```python\n  def f(): pass\n  ```\n'))
  const plugin = ed.state.plugins.find(p => p.key.startsWith('codeHighlighting'))
  assert.ok(plugin)
  assert.ok(!ed.state.plugins.some(p => p.key.startsWith('lowlight')))
  const classesAt = (word) => {
    const text = []
    ed.state.doc.descendants((n, pos) => { if (n.isText) text.push([pos, n.text]); })
    const [pos, t] = text.find(([, t]) => t.includes(word))
    const at = pos + t.indexOf(word)
    return plugin.getState(ed.state).find(at, at + word.length).map(d => d.type.attrs.class).join(' ')
  }
  assert.match(classesAt('const'), /hljs-keyword/)
  assert.match(classesAt('def'), /hljs-keyword/)
  // An edit outside code keeps the same decoration set object.
  const before = plugin.getState(ed.state)
  ed.commands.setTextSelection(3)
  assert.equal(plugin.getState(ed.state), before)
  // Editing the code re-highlights it.
  let codeStart = -1
  ed.state.doc.descendants((n, pos) => { if (codeStart < 0 && n.type.name === 'codeBlock') codeStart = pos + 1 })
  ed.view.dispatch(ed.state.tr.insertText('return ', codeStart))
  assert.match(classesAt('return'), /hljs-keyword/)
  // Same decorations as building them from scratch, after a mix of edits.
  const all = () => plugin.getState(ed.state).find().map(d => `${d.from}-${d.to}:${d.type.attrs.class}`).sort().join('|')
  ed.view.dispatch(ed.state.tr.insertText('x', 2))                       // before the code
  ed.view.dispatch(ed.state.tr.insertText('\nlet b = 2', codeStart + 5)) // inside it
  ed.view.dispatch(ed.state.tr.delete(codeStart + 1, codeStart + 4))      // part of it
  let blockPos = -1
  ed.state.doc.descendants((n, pos) => { if (blockPos < 0 && n.type.name === 'codeBlock') blockPos = pos })
  const tagged = plugin.getState(ed.state)
  ed.view.dispatch(ed.state.tr.setNodeAttribute(blockPos, 'language', 'python')) // language only
  assert.notEqual(plugin.getState(ed.state), tagged)
  const incremental = all()
  const fresh = makeEditor()
  fresh.commands.setContent(ed.getJSON())
  const freshPlugin = fresh.state.plugins.find(p => p.key.startsWith('codeHighlighting'))
  assert.equal(incremental, freshPlugin.getState(fresh.state).find().map(d => `${d.from}-${d.to}:${d.type.attrs.class}`).sort().join('|'))
})
