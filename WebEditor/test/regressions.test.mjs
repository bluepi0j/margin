// Regressions from the October 2026 review: Markdown fidelity, find & replace,
// source-mode place keeping, export. Core tests use their own editor; the
// page tests bootstrap the page like page.test.mjs.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { makeEditor, roundTrip, core } from './setup.mjs'

const require = createRequire(import.meta.url)
const { GapCursor } = await import(require.resolve('@tiptap/pm/gapcursor'))

document.body.innerHTML = `<div id="page"><div id="editor"></div><textarea id="source" hidden></textarea></div><div id="empty"></div><div id="word-count"></div>`
window.webkit = { messageHandlers: { margin: { postMessage: () => {} } } }
globalThis.CSS ??= { escape: s => s }
await import('./.build/page.mjs')
const margin = window.margin
const pageEditor = () => document.querySelector('.ProseMirror').editor

const editor = makeEditor()
const same = md => assert.equal(roundTrip(editor, md), md)
const md = e => core.serializeMarkdown(e, e.getJSON())

function type(e, text) {
  for (const ch of text) {
    const { view } = e
    const { from, to } = view.state.selection
    const handled = view.someProp('handleTextInput', f => f(view, from, to, ch, () => view.state.tr.insertText(ch, from, to)))
    if (!handled) view.dispatch(view.state.tr.insertText(ch, from, to))
  }
}

function findInput(value) {
  const input = document.querySelector('.find-input')
  input.value = value
  input.dispatchEvent(new window.Event('input'))
}

// --- Front matter ----------------------------------------------------------

test('front matter is kept when a node ends up before it', () => {
  const json = { type: 'doc', content: [
    { type: 'paragraph', content: [{ type: 'text', text: 'x' }] },
    { type: 'frontMatter', content: [{ type: 'text', text: 'title: Hello' }] },
  ] }
  assert.equal(core.serializeMarkdown(editor, json), '---\ntitle: Hello\n---\n\nx\n')
})

test('typing at a gap cursor before the front matter keeps the YAML', () => {
  margin.open('fm', '---\ntitle: Hello\n---\n\nBody\n', '', true)
  const ed = pageEditor()
  ed.view.dispatch(ed.state.tr.setSelection(new GapCursor(ed.state.doc.resolve(0))))
  ed.view.dispatch(ed.state.tr.insertText('x'))
  assert.equal(margin.getMarkdown('fm'), '---\ntitle: Hello\n---\n\nx\n\nBody\n')
  margin.close('fm')
})

test('a front-matter-only file gets a paragraph to type in and does not grow', () => {
  const json = core.parseMarkdown(editor, '---\na: 1\n---\n')
  assert.ok(json.content.some(n => n.type === 'paragraph'))
  same('---\na: 1\n---\n')
})

// --- Links, entities, escaping -----------------------------------------------

test('bare URLs and addresses stay bare', () => {
  same('Visit https://example.com today\n')
  same('mail me@example.com now\n')
  same('[Example](https://example.com)\n')
})

test('a link whose target has a space is written in angle brackets', () => {
  const json = { type: 'doc', content: [{ type: 'paragraph', content: [{ type: 'text', text: 'doc', marks: [{ type: 'link', attrs: { href: 'notes/my file.md' } }] }] }] }
  const once = core.serializeMarkdown(editor, json)
  assert.equal(once, '[doc](<notes/my file.md>)\n')
  assert.equal(roundTrip(editor, once), once)
})

test('named entities the parser leaves alone are written as they were', () => {
  same('&copy; 2024 Acme\n')
  same('a&nbsp;b\n')
  assert.equal(roundTrip(editor, 'a &amp;lt; b\n'), 'a &amp;lt; b\n')
})

test('"==" is only escaped when it would open a highlight', () => {
  same('a == b\n')
  same('use == not =\n')
  assert.equal(core.escapeText('==x== and ==y=='), '\\=\\=x\\=\\= and \\=\\=y\\=\\=')
})

test('block syntax at the start of a paragraph line is escaped', () => {
  const p = content => ({ type: 'doc', content: [{ type: 'paragraph', content }] })
  const cases = [
    [p([{ type: 'text', text: 'a' }, { type: 'hardBreak' }, { type: 'text', text: '# b' }]), 'a  \n\\# b\n'],
    [p([{ type: 'text', text: 'a' }, { type: 'hardBreak' }, { type: 'text', text: '- b' }]), 'a  \n\\- b\n'],
    [p([{ type: 'text', text: '1. not a list' }]), '1\\. not a list\n'],
    [p([{ type: 'text', text: '---' }]), '\\---\n'],
    [p([{ type: 'text', text: '    indented' }]), '&#32;   indented\n'],
  ]
  for (const [json, expected] of cases) {
    const once = core.serializeMarkdown(editor, json)
    assert.equal(once, expected)
    assert.equal(roundTrip(editor, once), once)
  }
  // Not at a line start it is just text.
  assert.equal(core.serializeMarkdown(editor, p([{ type: 'text', text: 'see # b' }])), 'see # b\n')
})

// --- tidy() stays out of verbatim content ---------------------------------------

test('raw HTML blocks keep their blank lines and entities', () => {
  same('<pre>\na\n\n\nb\n</pre>\n')
  same('<div>\n  &nbsp;\n</div>\n')
  same('<!--\na\n\n\nb\n-->\n')
})

test('fences in quotes and nested lists keep their content', () => {
  same('> ```html\n> &nbsp;\n> ```\n')
  same('- a\n  - b\n    ```html\n    &nbsp;\n    ```\n')
})

// --- Typing ---------------------------------------------------------------------

test('typing $$x$$ at the start of a paragraph keeps the rest of it', () => {
  const e = makeEditor()
  e.commands.setContent(core.parseMarkdown(e, 'hello world\n'))
  e.commands.setTextSelection(1)
  type(e, '$$a$$')
  assert.equal(md(e), '$$\na\n$$\n\nhello world\n')
})

// --- Find & replace -----------------------------------------------------------

test('Replace moves past a replacement that contains the query', () => {
  margin.open('rep', 'cat and cat\n', '', true)
  margin.find('replace')
  findInput('cat')
  document.querySelector('.replace-input').value = 'cats'
  document.querySelector('[data-act="replace"]').click()
  document.querySelector('[data-act="replace"]').click()
  assert.equal(margin.getMarkdown('rep'), 'cats and cats\n')
  // Nothing outside the replacements is left: a third click changes nothing.
  document.querySelector('[data-act="replace"]').click()
  assert.equal(margin.getMarkdown('rep'), 'cats and cats\n')
  assert.equal(document.querySelector('.find-count').textContent, '2 matches')
  document.querySelector('[data-act="close"]').click()
  margin.close('rep')
})

test('closing the find bar clears highlights in every tab', () => {
  margin.open('fa', 'alpha beta alpha\n', '', true)
  margin.open('fb', 'gamma\n', '', true)
  margin.activate('fa')
  margin.find('open')
  findInput('alpha')
  assert.equal(document.querySelectorAll('.find-match').length, 2)
  margin.activate('fb')
  document.querySelector('[data-act="close"]').click()
  margin.activate('fa')
  assert.equal(document.querySelectorAll('.find-match').length, 0)
  margin.close('fa')
  margin.close('fb')
})

// --- Source map ----------------------------------------------------------------

function mapped(markdownIn, mutate) {
  const e = makeEditor()
  e.commands.setContent(core.parseMarkdown(e, markdownIn))
  mutate?.(e)
  const markdown = core.serializeMarkdown(e, e.getJSON())
  return { e, doc: e.state.doc, markdown, offsets: core.blockOffsets(e, e.state.doc, markdown) }
}

test('source map: empty paragraphs after a long paragraph do not pull the caret back', () => {
  const first = 'This is a long first paragraph with more than twenty four characters in it.'
  const { doc, markdown, offsets } = mapped(`${first}\n\nSecond paragraph.\n`, e => {
    e.commands.setTextSelection(1 + first.length)
    e.commands.keyboardShortcut('Enter')
    e.commands.keyboardShortcut('Enter')
  })
  const pos = 1 + first.indexOf('characters')
  assert.equal(core.sourceOffset(doc, offsets, markdown, pos), markdown.indexOf('characters'))
  assert.equal(core.docPosition(doc, offsets, markdown, markdown.indexOf('characters')), pos)
})

test('source map: a block whose first words also appear inside an earlier block', () => {
  const { markdown, offsets } = mapped('I said hello to the world and then I said goodbye to it.\n\nI said goodbye to it.\n')
  assert.equal(offsets[1], markdown.indexOf('\n\n') + 2)
})

test('source map: an emoji before the caret', () => {
  const { doc, markdown, offsets } = mapped('Hi 👋 there friend, how are you?\n')
  const pos = 1 + doc.child(0).textContent.indexOf('friend')
  assert.equal(core.sourceOffset(doc, offsets, markdown, pos), markdown.indexOf('friend'))
  assert.equal(core.docPosition(doc, offsets, markdown, markdown.indexOf('friend')), pos)
})

// --- Export ------------------------------------------------------------------------

test('export carries no editor-only markup', async () => {
  margin.open('ex', '```js\nlet x\n```\n', '', true)
  assert.doesNotMatch((await margin.exportHTML()).body, /class="diagram"/)
  margin.close('ex')
  margin.open('ex2', '', '', true)
  assert.doesNotMatch((await margin.exportHTML()).body, /data-placeholder|is-editor-empty/)
  margin.close('ex2')
})
