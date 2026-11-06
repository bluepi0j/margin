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
