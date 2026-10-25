// Source mode keeps your place: document positions ↔ Markdown offsets.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { makeEditor, core } from './setup.mjs'

const MD = `# Trip **notes**

Three slow days with *a lot* of tea and \`code\`.

- First item
- Second item with [a link](https://example.com)

> A quote here

| Day | Plan |
| --- | --- |
| Fri | Temples |

\`\`\`js
const x = 1
\`\`\`

Last paragraph.
`

function setup() {
  const editor = makeEditor()
  editor.commands.setContent(core.parseMarkdown(editor, MD))
  const markdown = core.serializeMarkdown(editor, editor.getJSON())
  const doc = editor.state.doc
  return { editor, doc, markdown, offsets: core.blockOffsets(editor, doc, markdown) }
}

// Position of the first occurrence of `text` in the document.
function posOf(doc, text) {
  let found = -1
  doc.descendants((node, pos) => {
    if (found >= 0) return false
    if (node.isText && node.text.includes(text)) found = pos + node.text.indexOf(text)
  })
  assert.ok(found >= 0, text)
  return found
}

test('every block is found in the Markdown, in order', () => {
  const { doc, markdown, offsets } = setup()
  assert.equal(offsets.length, doc.childCount)
  for (let i = 1; i < offsets.length; i++) assert.ok(offsets[i] > offsets[i - 1], `block ${i} after block ${i - 1}`)
  assert.ok(markdown.slice(offsets[0]).startsWith('# Trip'))
  assert.ok(markdown.slice(offsets.at(-1)).startsWith('Last paragraph'))
})

test('a position maps to the same words in the Markdown', () => {
  const { doc, markdown, offsets } = setup()
  for (const word of ['notes', 'slow', 'tea', 'code', 'Second', 'link', 'quote', 'Temples', 'const', 'Last']) {
    // Just before the word, or before the markup that opens it ("**notes", "- Second").
    const at = core.sourceOffset(doc, offsets, markdown, posOf(doc, word))
    const after = markdown.slice(at).replace(/^(?:\s+|[*_`[]+|[-*+] |\d+\. |> )+/, '')
    assert.ok(after.startsWith(word), `${word}: got ${JSON.stringify(markdown.slice(at, at + 12))}`)
  }
})

test('and maps back to where it came from', () => {
  const { doc, markdown, offsets } = setup()
  for (const word of ['notes', 'slow', 'tea', 'code', 'Second', 'link', 'quote', 'Temples', 'const', 'Last']) {
    const pos = posOf(doc, word)
    const back = core.docPosition(doc, offsets, markdown, core.sourceOffset(doc, offsets, markdown, pos))
    assert.equal(back, pos, word)
  }
})

test('an offset inside markup lands on the nearby text', () => {
  const { doc, markdown, offsets } = setup()
  // Inside "**" before "notes": should land at the start of "notes".
  const stars = markdown.indexOf('**notes')
  assert.equal(core.docPosition(doc, offsets, markdown, stars + 1), posOf(doc, 'notes'))
})

test('Markdown edited by hand still finds its blocks', () => {
  const { editor, doc } = setup()
  const handEdited = MD.replace('- First item', '*   First item')   // a different bullet style
  const offsets = core.blockOffsets(editor, doc, handEdited)
  const at = core.sourceOffset(doc, offsets, handEdited, posOf(doc, 'Last'))
  assert.ok(handEdited.slice(at).startsWith('Last'))
})
