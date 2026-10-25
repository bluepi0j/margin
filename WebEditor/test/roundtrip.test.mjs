// Markdown that should come back exactly as written after parse -> serialize.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { makeEditor, roundTrip, core } from './setup.mjs'

const editor = makeEditor()
const same = (md) => assert.equal(roundTrip(editor, md), md)

test('headings and paragraphs', () => same('# Title\n\nSome text.\n\n## Sub\n\nMore.\n'))
test('inline marks', () => same('**bold** *italic* ~~strike~~ `code` ==mark== [link](https://a.com)\n'))
test('bullet and nested lists', () => same('- one\n- two\n  - nested\n'))
test('ordered list', () => same('1. one\n2. two\n'))
test('task list', () => same('- [ ] todo\n- [x] done\n'))
test('blockquote', () => same('> quote\n'))
test('code block keeps content verbatim', () => same('```js\nconst a = `x` * 2 // <b>&\n```\n'))
test('horizontal rule', () => same('a\n\n---\n\nb\n'))
test('inline and block math', () => same('Inline $E=mc^2$ math.\n\n$$\n\\int_0^1 x\\,dx\n$$\n'))
test('image', () => same('![alt](images/a.png)\n'))
test('image path with encoded space', () => same('![alt](my%20images/a.png)\n'))
test('table', () => {
  const out = roundTrip(editor, '| a | b |\n| --- | --- |\n| 1 | 2 |\n')
  assert.match(out, /^\| a +\| b +\|\n\| -+ \| -+ \|\n\| 1 +\| 2 +\|\n$/)
})

test('front matter is preserved', () => same('---\ntitle: Hello\ntags: [a, b]\n---\n\n# Body\n'))
test('block html is preserved', () => same('<div align="center">\n  <img src="x.png">\n</div>\n\nText.\n'))
test('inline html is preserved', () => same('Press <kbd>⌘</kbd> and a<br>b.\n'))
test('footnotes are preserved', () => same('Text with note[^1].\n\n[^1]: The note.\n'))

test('no needless escaping', () => {
  same('snake_case_name and 2 * 3 * 4 and a -> b & c < d\n')
  same('Price $5 and $10 today.\n')
  same('See [1] for details.\n')
})
test('escapes what would change meaning', () => {
  assert.equal(core.escapeText('*not italic*'), '\\*not italic\\*')
  assert.equal(core.escapeText('`tick`'), '\\`tick\\`')
  assert.equal(core.escapeText('<div>'), '&lt;div>')
  assert.equal(core.escapeText('$x$'), '\\$x$')
  assert.equal(core.escapeText('[a](b)'), '\\[a](b)')
})
test('literal text with escapes survives a second round trip', () => {
  const once = roundTrip(editor, 'a \\*b\\* c \\`d\\`\n')
  assert.equal(roundTrip(editor, once), once)
  assert.equal(once, 'a \\*b\\* c \\`d\\`\n')
})
test('CRLF input is normalized', () => same('# A\n\nb\n') || assert.equal(roundTrip(editor, '# A\r\n\r\nb\r\n'), '# A\n\nb\n'))
test('empty document', () => assert.equal(roundTrip(editor, ''), '\n'))
test('Chinese text', () => same('# 标题\n\n这是**中文**内容，包含 `代码` 和 [链接](https://example.com)。\n'))

test('documents are always schema-valid (standalone image)', () => {
  const json = core.parseMarkdown(editor, 'para\n\n![Logo](a.png)\n\n> ![b](b.png)\n')
  const node = editor.schema.nodeFromJSON(json)
  assert.doesNotThrow(() => node.check())
  assert.equal(core.serializeMarkdown(editor, json), 'para\n\n![Logo](a.png)\n\n> ![b](b.png)\n')
})
