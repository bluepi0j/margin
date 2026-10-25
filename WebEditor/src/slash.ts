// "/" menu: type a slash to insert a heading, list, table, diagram…
import { Extension, type Editor, type Range } from '@tiptap/core'
import Suggestion from '@tiptap/suggestion'
import { runCommand } from './editor'

interface Item {
  title: string
  hint: string
  icon: string
  keywords: string
  run: (editor: Editor) => void
}

const cmd = (name: string, args?: any) => (editor: Editor) => runCommand(editor, name, args)

const ITEMS: Item[] = [
  { title: 'Text', hint: 'Plain paragraph', icon: '¶', keywords: 'paragraph body', run: cmd('paragraph') },
  { title: 'Heading 1', hint: '#', icon: 'H1', keywords: 'title h1', run: cmd('heading', { level: 1 }) },
  { title: 'Heading 2', hint: '##', icon: 'H2', keywords: 'subtitle h2', run: cmd('heading', { level: 2 }) },
  { title: 'Heading 3', hint: '###', icon: 'H3', keywords: 'h3', run: cmd('heading', { level: 3 }) },
  { title: 'Bulleted list', hint: '-', icon: '•', keywords: 'bullet unordered ul', run: cmd('bulletList') },
  { title: 'Numbered list', hint: '1.', icon: '1.', keywords: 'ordered ol number', run: cmd('orderedList') },
  { title: 'Task list', hint: '[ ]', icon: '☐', keywords: 'todo checkbox check', run: cmd('taskList') },
  { title: 'Quote', hint: '>', icon: '❝', keywords: 'blockquote citation', run: cmd('blockquote') },
  { title: 'Code block', hint: '```', icon: '{ }', keywords: 'code snippet fence', run: cmd('codeBlock') },
  { title: 'Table', hint: '3 × 3', icon: '▦', keywords: 'table grid', run: cmd('table') },
  { title: 'Formula', hint: '$$', icon: '∑', keywords: 'math latex equation katex', run: cmd('blockMath') },
  { title: 'Diagram', hint: 'Mermaid', icon: '⧉', keywords: 'mermaid chart flowchart sequence graph', run: cmd('mermaid') },
  { title: 'Image', hint: 'From a file', icon: '▣', keywords: 'picture photo', run: () => window.margin.post({ type: 'pickImage' }) },
  { title: 'Divider', hint: '---', icon: '—', keywords: 'horizontal rule hr separator line', run: cmd('horizontalRule') },
]

function filter(query: string): Item[] {
  const q = query.toLowerCase().trim()
  if (!q) return ITEMS
  return ITEMS.filter(i => i.title.toLowerCase().includes(q) || i.keywords.includes(q))
}

class SlashMenu {
  el = document.createElement('div')
  items: Item[] = []
  index = 0
  command: ((item: Item) => void) | null = null

  constructor() {
    this.el.className = 'slash-menu'
    this.el.addEventListener('mousedown', e => e.preventDefault())
  }

  show(items: Item[], rect: DOMRect | null, command: (item: Item) => void) {
    this.command = command
    this.update(items, rect)
    document.body.appendChild(this.el)
  }

  update(items: Item[], rect: DOMRect | null, command?: (item: Item) => void) {
    if (command) this.command = command
    this.items = items
    this.index = Math.min(this.index, Math.max(0, items.length - 1))
    this.render()
    if (rect) this.place(rect)
  }

  render() {
    this.el.innerHTML = ''
    if (!this.items.length) {
      const empty = document.createElement('div')
      empty.className = 'slash-empty'
      empty.textContent = 'No matches'
      this.el.appendChild(empty)
      return
    }
    this.items.forEach((item, i) => {
      const row = document.createElement('div')
      row.className = 'slash-item' + (i === this.index ? ' selected' : '')
      row.innerHTML = `<span class="slash-icon"></span><span class="slash-title"></span><span class="slash-hint"></span>`
      row.querySelector('.slash-icon')!.textContent = item.icon
      row.querySelector('.slash-title')!.textContent = item.title
      row.querySelector('.slash-hint')!.textContent = item.hint
      row.addEventListener('mouseenter', () => {
        this.index = i
        this.highlight()
      })
      // mousedown, not click: see bubble.ts (WebKit can drop the click on a fresh popup).
      row.addEventListener('mousedown', e => {
        e.preventDefault()
        this.command?.(item)
      })
      this.el.appendChild(row)
    })
  }

  highlight() {
    this.el.querySelectorAll('.slash-item').forEach((row, i) => row.classList.toggle('selected', i === this.index))
    this.el.querySelector('.slash-item.selected')?.scrollIntoView({ block: 'nearest' })
  }

  place(rect: DOMRect) {
    const h = this.el.offsetHeight || 300
    const below = rect.bottom + 6
    const top = below + h > window.innerHeight - 8 ? Math.max(8, rect.top - h - 6) : below
    this.el.style.top = `${top}px`
    this.el.style.left = `${Math.min(rect.left, window.innerWidth - 268)}px`
  }

  key(event: KeyboardEvent): boolean {
    if (!this.items.length) return false
    if (event.key === 'ArrowDown') this.index = (this.index + 1) % this.items.length
    else if (event.key === 'ArrowUp') this.index = (this.index - 1 + this.items.length) % this.items.length
    else if (event.key === 'Enter' || event.key === 'Tab') {
      this.command?.(this.items[this.index])
      return true
    } else return false
    this.highlight()
    return true
  }

  hide() {
    this.el.remove()
    this.index = 0
  }
}

export const SlashCommands = Extension.create({
  name: 'slashCommands',
  addProseMirrorPlugins() {
    const menu = new SlashMenu()
    return [
      Suggestion<Item>({
        editor: this.editor,
        char: '/',
        startOfLine: false,
        allowedPrefixes: [' '],
        // Not inside code, where "/" is just a character.
        allow: ({ state, range }) => {
          const $from = state.doc.resolve(range.from)
          if ($from.parent.type.spec.code) return false
          return !$from.marks().some(mark => mark.type.name === 'code')
        },
        items: ({ query }) => filter(query),
        command: ({ editor, range, props }: { editor: Editor; range: Range; props: Item }) => {
          editor.chain().focus().deleteRange(range).run()
          props.run(editor)
        },
        render: () => ({
          onStart: props => menu.show(props.items, props.clientRect?.() ?? null, item => props.command(item)),
          // The range grows as the query is typed, so always use the latest props.
          onUpdate: props => menu.update(props.items, props.clientRect?.() ?? null, item => props.command(item)),
          onKeyDown: ({ event }) => {
            if (event.key === 'Escape') {
              menu.hide()
              return true
            }
            return menu.key(event)
          },
          onExit: () => menu.hide(),
        }),
      }),
    ]
  },
})
