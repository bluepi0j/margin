// Typing behaviour: Markdown shortcuts typed character by character, the
// way ProseMirror receives them from the keyboard.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { makeEditor, core } from './setup.mjs'

function fresh(md = '') {
  const editor = makeEditor()
  editor.commands.setContent(core.parseMarkdown(editor, md))
  editor.commands.focus('end')
  return editor
}

function type(editor, text) {
  for (const ch of text) {
    const { view } = editor
    const { from, to } = view.state.selection
    const handled = view.someProp('handleTextInput', f => f(view, from, to, ch, () => view.state.tr.insertText(ch, from, to)))
    if (!handled) view.dispatch(view.state.tr.insertText(ch, from, to))
  }
}

function enter(editor) {
  editor.commands.keyboardShortcut('Enter')
}

const md = editor => core.serializeMarkdown(editor, editor.getJSON())

test('"# " makes a heading', () => {
  const e = fresh()
  type(e, '# Title')
  assert.equal(md(e), '# Title\n')
})

test('"### " makes heading 3', () => {
  const e = fresh()
  type(e, '### Small')
  assert.equal(md(e), '### Small\n')
})

test('"- " makes a bullet list, "1. " an ordered list', () => {
  let e = fresh()
  type(e, '- one')
  assert.equal(md(e), '- one\n')
  e = fresh()
  type(e, '1. first')
  assert.equal(md(e), '1. first\n')
})

test('"[ ] " makes a task list', () => {
  const e = fresh()
  type(e, '[ ] todo')
  assert.equal(md(e), '- [ ] todo\n')
})

test('"> " makes a quote', () => {
  const e = fresh()
  type(e, '> wise')
  assert.equal(md(e), '> wise\n')
})

test('**bold**, *italic*, ~~strike~~, `code`, ==mark==', () => {
  const e = fresh()
  type(e, 'a **b** *c* ~~d~~ `e` ==f== g')
  assert.equal(md(e), 'a **b** *c* ~~d~~ `e` ==f== g\n')
})

test('$x$ makes inline math', () => {
  const e = fresh()
  type(e, 'see $x^2$ here')
  const json = e.getJSON()
  assert.equal(json.content[0].content.find(n => n.type === 'inlineMath')?.attrs.latex, 'x^2')
  assert.equal(md(e), 'see $x^2$ here\n')
})

test('prices are not math', () => {
  const e = fresh()
  type(e, 'costs $5 and $10')
  assert.equal(md(e), 'costs $5 and $10\n')
})

test('$$x$$ on its own line makes block math', () => {
  const e = fresh()
  type(e, '$$a+b$$')
  assert.equal(e.getJSON().content[0].type, 'blockMath')
})

test('``` + Enter makes a code block', () => {
  const e = fresh()
  type(e, '```js ')
  type(e, 'let x')
  assert.equal(md(e), '```js\nlet x\n```\n')
})

test('--- makes a divider', () => {
  const e = fresh('above')
  enter(e)
  type(e, '---')
  assert.ok(e.getJSON().content.some(n => n.type === 'horizontalRule'))
})

test('toolbar commands', () => {
  const e = fresh('word')
  e.commands.selectAll()
  core.runCommand(e, 'bold')
  assert.equal(md(e), '**word**\n')
  core.runCommand(e, 'heading', { level: 2 })
  assert.equal(md(e), '## **word**\n')
  core.runCommand(e, 'heading', { level: 0 })
  core.runCommand(e, 'bulletList')
  assert.equal(md(e), '- **word**\n')
  assert.equal(core.selectionState(e).bulletList, true)
})

test('insert table and image', () => {
  const e = fresh('')
  core.runCommand(e, 'table')
  assert.match(md(e), /^\| +\| +\| +\|\n\| -+ \| -+ \| -+ \|/)
  const e2 = fresh('')
  core.runCommand(e2, 'image', { src: 'assets/pic%20one.png' })
  assert.equal(md(e2), '![pic one](assets/pic%20one.png)\n')
})

test('[text](url) makes a link, ![alt](src) an image', () => {
  const e = fresh()
  type(e, 'see [docs](notes/a.md) and ![pic](img.png) end')
  assert.equal(md(e), 'see [docs](notes/a.md) and ![pic](img.png) end\n')
  const json = JSON.stringify(e.getJSON())
  assert.match(json, /"type":"link"/)
  assert.match(json, /"type":"image"/)
})

test('an image inserted on an empty line gets its own paragraph', () => {
  const e = fresh('above')
  enter(e)
  core.runCommand(e, 'image', { src: 'a.png' })
  type(e, 'below')
  assert.equal(md(e), 'above\n\n![a](a.png)\n\nbelow\n')
})

test('"- " then "[ ] " turns the bullet into a task', () => {
  const e = fresh()
  type(e, '- [ ] write docs')
  assert.equal(md(e), '- [ ] write docs\n')
  assert.equal(e.getJSON().content[0].type, 'taskList')
  const e2 = fresh()
  type(e2, '- [x] done')
  assert.equal(md(e2), '- [x] done\n')
})

// WebKit's smart dashes replace the "--" just typed with "—"; ProseMirror sees
// that as text input over the two hyphens.
function substitute(editor, back, replacement) {
  const { view } = editor
  const { from } = view.state.selection
  const handled = view.someProp('handleTextInput', f => f(view, from - back, from, replacement, () => view.state.tr))
  if (!handled) view.dispatch(view.state.tr.insertText(replacement, from - back, from))
}

test('smart dashes and quotes are undone in code blocks', () => {
  const e = fresh('```mermaid\ngraph LR\n```')
  e.commands.focus('end')
  type(e, '\n  A --')
  substitute(e, 2, '—')
  type(e, '> B')
  type(e, ' %% “note” ‘x’')
  assert.equal(md(e), '```mermaid\ngraph LR\n  A --> B %% "note" \'x\'\n```\n')
})

test('smart dashes and quotes are undone in inline code', () => {
  const e = fresh('Run `ab` now')
  let inside = 0
  e.state.doc.descendants((node, pos) => {
    if (node.isText && node.text === 'ab') inside = pos + 1   // between a and b
  })
  e.commands.setTextSelection(inside)
  type(e, '--')
  substitute(e, 2, '—')
  type(e, '“')
  assert.equal(md(e), 'Run `a--"b` now\n')
})

test('prose keeps smart punctuation', () => {
  const e = fresh('Hello')
  e.commands.focus('end')
  type(e, ' “quoted” —')
  assert.equal(md(e), 'Hello “quoted” —\n')
})
