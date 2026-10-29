// Builds the single TipTap editor that lives in each window, and the
// commands the native toolbar / menus call.
import { Editor, Extension, InputRule } from '@tiptap/core'
import StarterKit from '@tiptap/starter-kit'
import Strike from '@tiptap/extension-strike'
import { Link } from '@tiptap/extension-link'
import Placeholder from '@tiptap/extension-placeholder'
import Image from '@tiptap/extension-image'
import Highlight from '@tiptap/extension-highlight'
import { TableKit } from '@tiptap/extension-table'
import { TaskList, TaskItem } from '@tiptap/extension-list'
import CodeBlockLowlight from '@tiptap/extension-code-block-lowlight'
import { Markdown } from '@tiptap/markdown'
import { common, createLowlight } from 'lowlight'
import katex from 'katex'
import type { Node as PMNode } from '@tiptap/pm/model'
import { Plugin } from '@tiptap/pm/state'

import { FrontMatter, HtmlBlock, HtmlInline, FootnoteRef, FootnoteDef, MarginInlineMath, MarginBlockMath } from './nodes'
import { installMinimalEscaping } from './markdown'
import { openPopover } from './popover'
import { Find } from './find'
import { SlashCommands } from './slash'

const lowlight = createLowlight(common)
export const codeLanguages = lowlight.listLanguages().sort()

/** Base URL that relative image paths resolve against (set per document). */
let imageBase = ''
export function setImageBase(base: string) {
  imageBase = base
}

function encodePath(path: string) {
  let decoded = path
  try {
    decoded = decodeURI(path)
  } catch {}
  return encodeURI(decoded).replace(/#/g, '%23')
}

export function resolveImageSrc(src: string): string {
  if (!src) return src
  if (/^[a-z][a-z0-9+.-]*:/i.test(src)) {
    // file:///abs/path -> served through the app's scheme handler
    return src.startsWith('file://') ? 'margin-file://' + src.slice('file://'.length) : src
  }
  if (src.startsWith('/')) return 'margin-file://' + encodePath(src)
  if (!imageBase) return src
  return imageBase + encodePath(src)
}

function renderKatex(latex: string, displayMode: boolean) {
  if (!latex.trim()) return `<span class="math-empty">${displayMode ? 'Empty formula' : '…'}</span>`
  try {
    return katex.renderToString(latex, { displayMode, throwOnError: false })
  } catch (e) {
    return `<span class="math-error">${String(e)}</span>`
  }
}

// ---------------------------------------------------------------------------
// Popovers for math, links and code languages

function nodeRect(editor: Editor, pos: number): DOMRect {
  const dom = editor.view.nodeDOM(pos) as HTMLElement | null
  if (dom && dom.getBoundingClientRect) return dom.getBoundingClientRect()
  const c = editor.view.coordsAtPos(pos)
  return new DOMRect(c.left, c.top, 0, c.bottom - c.top)
}

function caretRect(editor: Editor): DOMRect {
  const { from } = editor.state.selection
  const c = editor.view.coordsAtPos(from)
  return new DOMRect(c.left, c.top, 0, c.bottom - c.top)
}

export function editMath(editor: Editor, kind: 'inline' | 'block', pos?: number) {
  const display = kind === 'block'
  const type = display ? 'blockMath' : 'inlineMath'
  const existing = pos !== undefined ? editor.state.doc.nodeAt(pos) : null
  const { from, to } = editor.state.selection
  const initial = existing?.attrs.latex ?? (from !== to ? editor.state.doc.textBetween(from, to, ' ') : '')
  openPopover({
    anchor: pos !== undefined ? nodeRect(editor, pos) : caretRect(editor),
    value: initial,
    label: display ? 'Block formula (LaTeX)' : 'Inline formula (LaTeX)',
    placeholder: display ? '\\int_0^1 x^2\\,dx' : 'E = mc^2',
    multiline: display,
    preview: v => renderKatex(v, display),
    onSubmit: value => {
      const latex = value.trim()
      const chain = editor.chain().focus()
      if (existing && pos !== undefined) {
        if (!latex) chain.deleteRange({ from: pos, to: pos + existing.nodeSize }).run()
        else chain.command(({ tr }) => (tr.setNodeMarkup(pos, undefined, { ...existing.attrs, latex }), true)).run()
      } else if (latex) {
        if (display) chain.insertContent({ type, attrs: { latex } }).run()
        else chain.deleteSelection().insertContent({ type, attrs: { latex } }).run()
      }
    },
    onCancel: () => editor.commands.focus(),
  })
}

export function editLink(editor: Editor) {
  if (editor.isActive('link')) editor.chain().extendMarkRange('link').run()
  const href: string = editor.getAttributes('link').href ?? ''
  const { from, to } = editor.state.selection
  openPopover({
    anchor: caretRect(editor),
    value: href,
    label: 'Link',
    placeholder: 'https://example.com or notes/other.md',
    onSubmit: value => {
      const url = value.trim()
      const chain = editor.chain().focus()
      if (!url) {
        chain.extendMarkRange('link').unsetLink().run()
      } else if (from === to && !editor.isActive('link')) {
        chain.insertContent({ type: 'text', text: url, marks: [{ type: 'link', attrs: { href: url } }] }).run()
      } else {
        chain.extendMarkRange('link').setLink({ href: url }).run()
      }
    },
    onCancel: () => editor.commands.focus(),
    secondary: href ? { title: 'Remove link', run: () => editor.chain().focus().extendMarkRange('link').unsetLink().run() } : undefined,
  })
}

// ---------------------------------------------------------------------------
// Mermaid: rendered by a separately loaded bundle (see mermaid-entry.ts)

let mermaidLoading: Promise<void> | null = null
function loadMermaid(): Promise<void> {
  if ((window as any).MarginMermaid) return Promise.resolve()
  mermaidLoading ??= new Promise((resolve, reject) => {
    const script = document.createElement('script')
    script.src = 'mermaid.js'
    script.onload = () => resolve()
    script.onerror = () => reject(new Error('Could not load the diagram renderer'))
    document.head.appendChild(script)
  })
  return mermaidLoading
}

const mermaidCache = new Map<string, string>()
export async function renderMermaid(code: string): Promise<string> {
  const cached = mermaidCache.get(code)
  if (cached) return cached
  await loadMermaid()
  const svg = (window as any).MarginMermaid.render(code)
  if (mermaidCache.size > 50) mermaidCache.clear()
  mermaidCache.set(code, svg)
  return svg
}

export const MERMAID_SAMPLE = 'graph LR\n  A[Idea] --> B[Draft]\n  B --> C{Good?}\n  C -->|Yes| D[Publish]\n  C -->|No| B'

// ---------------------------------------------------------------------------
// Code block with a language label and a copy button

const MarginCodeBlock = CodeBlockLowlight.extend({
  // TipTap's own serializer always writes ```; a line of ``` inside the code
  // would then close the block early when the file is read back. Emit a
  // fence one longer than any backtick run in the content (CommonMark).
  renderMarkdown: (node: any, h: any) => {
    const language = node.attrs?.language || ''
    const code = node.content ? h.renderChildren(node.content) : ''
    const longest = Math.max(0, ...[...code.matchAll(/`+/g)].map(m => m[0].length))
    const fence = '`'.repeat(Math.max(3, longest + 1))
    return [fence + language, code, fence].join('\n')
  },
  addNodeView() {
    return ({ node, editor, getPos }) => {
      let current: PMNode = node
      const dom = document.createElement('div')
      dom.className = 'code-block'

      const header = document.createElement('div')
      header.className = 'code-header'
      header.contentEditable = 'false'

      const lang = document.createElement('button')
      lang.className = 'code-lang'
      lang.addEventListener('mousedown', e => {
        e.preventDefault()
        if (e.button !== 0) return
        const pos = typeof getPos === 'function' ? getPos() : undefined
        if (pos === undefined) return
        openPopover({
          anchor: lang.getBoundingClientRect(),
          value: current.attrs.language ?? '',
          label: 'Language',
          placeholder: 'plain text',
          suggestions: codeLanguages,
          onSubmit: v =>
            editor
              .chain()
              .command(({ tr }) => (tr.setNodeMarkup(pos, undefined, { ...current.attrs, language: v.trim() || null }), true))
              .run(),
        })
      })

      const copy = document.createElement('button')
      copy.className = 'code-copy'
      copy.textContent = 'Copy'
      copy.addEventListener('mousedown', e => {
        e.preventDefault()
        if (e.button !== 0) return
        window.margin.post({ type: 'copy', text: current.textContent })
        copy.textContent = 'Copied'
        setTimeout(() => (copy.textContent = 'Copy'), 1200)
      })

      // Mermaid blocks show the diagram; "Edit" reveals the source and puts
      // the caret at its end, "Done" goes back to the diagram.
      const setEditing = (on: boolean) => {
        dom.classList.toggle('editing', on)
        toggle.textContent = on ? 'Done' : 'Edit'
        const pos = typeof getPos === 'function' ? getPos() : undefined
        if (on && pos !== undefined) editor.chain().focus().setTextSelection(pos + 1 + current.content.size).run()
      }
      const toggle = document.createElement('button')
      toggle.className = 'code-toggle'
      toggle.addEventListener('mousedown', e => {
        e.preventDefault()
        if (e.button !== 0) return
        setEditing(!dom.classList.contains('editing'))
      })

      header.append(toggle, lang, copy)
      const pre = document.createElement('pre')
      const code = document.createElement('code')
      // Code is not prose: no spelling squiggles, and (since WebKit skips text
      // checking there) no smart dashes or quotes turning `-->` into `—>`.
      pre.spellcheck = false
      pre.appendChild(code)
      const preview = document.createElement('div')
      preview.className = 'diagram'
      preview.contentEditable = 'false'
      preview.addEventListener('dblclick', () => setEditing(true))
      dom.append(header, pre, preview)

      let renderTimer: number | undefined
      let rendered = ''
      const renderDiagram = () => {
        const source = current.textContent
        if (source === rendered) return
        rendered = source
        if (!source.trim()) {
          preview.innerHTML = '<div class="diagram-note">Empty diagram</div>'
          return
        }
        renderMermaid(source)
          .then(svg => {
            if (rendered === source) preview.innerHTML = svg
          })
          .catch(err => {
            if (rendered === source) preview.innerHTML = `<div class="diagram-note error">${String(err.message ?? err).replace(/</g, '&lt;')}</div>`
          })
      }

      const sync = () => {
        const language = current.attrs.language
        lang.textContent = language || 'plain text'
        code.className = language ? `language-${language}` : ''
        const isMermaid = language === 'mermaid'
        dom.classList.toggle('has-lang', !!language)
        dom.classList.toggle('is-mermaid', isMermaid)
        toggle.hidden = !isMermaid
        if (isMermaid) {
          if (!current.textContent.trim()) dom.classList.add('editing')
          toggle.textContent = dom.classList.contains('editing') ? 'Done' : 'Edit'
          clearTimeout(renderTimer)
          renderTimer = window.setTimeout(renderDiagram, rendered ? 300 : 0)
        }
      }
      sync()

      return {
        dom,
        contentDOM: code,
        update: (updated: PMNode) => {
          if (updated.type !== current.type) return false
          current = updated
          sync()
          return true
        },
        stopEvent: (e: Event) => header.contains(e.target as Node) || preview.contains(e.target as Node),
        // Our own class changes on the block (editing, is-mermaid…) aren't
        // document edits; if ProseMirror saw them it would redraw the block
        // and drop the editing state.
        ignoreMutation: (m: any) =>
          (m.type === 'attributes' && m.target === dom) || header.contains(m.target as Node) || preview.contains(m.target as Node),
      }
    }
  },
})

// Image: Markdown images are inline; relative paths resolve against the file.
const MarginImage = Image.extend({
  renderHTML({ HTMLAttributes }) {
    // data-src keeps the path as written, for HTML export.
    return ['img', { ...HTMLAttributes, src: resolveImageSrc(HTMLAttributes.src), 'data-src': HTMLAttributes.src }]
  },
}).configure({ inline: true, allowBase64: true })

// ⌘⇧S belongs to Save As, so strike moves to ⌘⇧X.
const MarginStrike = Strike.extend({
  addKeyboardShortcuts() {
    return { 'Mod-Shift-x': () => this.editor.commands.toggleStrike() }
  },
})

// Links: a bare URL or address stays bare on save (the parser autolinks it;
// TipTap would write it back as [url](url)), and an href with spaces goes in
// <…> so it can be read back as a link.
const MarginLink = Link.extend({
  renderMarkdown: (node: any, h: any, context?: any) => {
    const href: string = node.attrs?.href ?? ''
    const title: string = node.attrs?.title ?? ''
    const text: string = h.renderChildren(node)
    // The serializer renders marks around a placeholder; the real text is in the context.
    const actual: string = context?.meta?.markText ?? text
    if (!title && (actual === href || `mailto:${actual}` === href)) return text
    const target = /\s/.test(href) ? `<${href}>` : href
    return title ? `[${text}](${target} "${title}")` : `[${text}](${target})`
  },
}).configure({ openOnClick: false, autolink: true, linkOnPaste: true, enableClickSelection: false })

// macOS "smart quotes and dashes" (WebKit follows the system setting) turn
// `-->` into `—>` and `"x"` into “x”, which breaks code and diagrams. Code is
// marked spellcheck=false, which keeps WebKit's text checking out of it; this
// catches what still arrives as typed text there. Prose keeps the user's choice.
const SMART = /[—–“”‘’]/
export function plainCodeText(text: string) {
  return text.replace(/[—–]/g, '--').replace(/[“”]/g, '"').replace(/[‘’]/g, "'")
}
const PlainCode = Extension.create({
  name: 'plainCode',
  addProseMirrorPlugins() {
    return [
      new Plugin({
        props: {
          handleTextInput(view, from, to, text) {
            if (!SMART.test(text)) return false
            const $from = view.state.doc.resolve(from)
            const inCode = $from.parent.type.spec.code
              || (view.state.storedMarks ?? $from.marks()).some(m => m.type.name === 'code')
            if (!inCode) return false
            view.dispatch(view.state.tr.insertText(plainCodeText(text), from, to))
            return true
          },
        },
      }),
    ]
  },
})

const MarginKeys = Extension.create({
  name: 'marginKeys',
  // Lowest priority: lists, tables and code blocks get Tab first.
  priority: 1,
  addKeyboardShortcuts() {
    return {
      // Otherwise Tab would move keyboard focus out of the editor.
      Tab: () => true,
      'Shift-Tab': () => true,
      'Mod-k': () => (editLink(this.editor), true),
      // Leave ⌘⇧H to the app; highlight lives on ⌘⇧E.
      'Mod-Shift-e': () => this.editor.commands.toggleHighlight(),
    }
  },
})

// Typing [text](url) turns into a link, ![alt](src) into an image.
const MarkdownLinks = Extension.create({
  name: 'markdownLinks',
  addInputRules() {
    return [
      new InputRule({
        find: /(?:^|[^!\\])(\[([^\]]+)\]\(([^)\s]+)(?:\s+"([^"]*)")?\))$/,
        handler: ({ state, range, match }) => {
          const [, whole, text, href, title] = match
          const start = range.to - whole.length
          const mark = state.schema.marks.link.create({ href, title: title ?? null })
          state.tr.replaceWith(start, range.to, state.schema.text(text, [mark])).removeStoredMark(mark)
        },
      }),
      // "- [ ] " typed as "- " then "[ ] ": the bullet becomes a task.
      new InputRule({
        find: /^\[([ xX])\]\s$/,
        handler: ({ state, range, match, chain }) => {
          const $from = state.doc.resolve(range.from)
          if ($from.depth < 2 || $from.node(-1).type.name !== 'listItem') return null
          chain()
            .deleteRange(range)
            .toggleTaskList()
            .updateAttributes('taskItem', { checked: match[1].toLowerCase() === 'x' })
            .run()
        },
      }),
      new InputRule({
        find: /!\[([^\]]*)\]\(([^)\s]+)\)$/,
        handler: ({ state, range, match }) => {
          const [, alt, src] = match
          state.tr.replaceWith(range.from, range.to, state.schema.nodes.image.create({ src, alt }))
        },
      }),
    ]
  },
})

// ---------------------------------------------------------------------------

export function createEditor(element: HTMLElement): Editor {
  const editor = new Editor({
    element,
    extensions: [
      StarterKit.configure({
        codeBlock: false,
        strike: false,
        underline: false,
        trailingNode: false,
        code: { HTMLAttributes: { spellcheck: 'false' } },
        link: false,
      }),
      MarginStrike,
      MarginLink,
      MarginCodeBlock.configure({ lowlight, defaultLanguage: null, enableTabIndentation: true } as any),
      Placeholder.configure({ placeholder: 'Start writing…' }),
      MarginImage,
      Highlight,
      TableKit.configure({ table: { resizable: false } }),
      TaskList,
      TaskItem.configure({ nested: true }),
      MarginInlineMath.configure({
        katexOptions: { throwOnError: false },
        onClick: (_node, pos) => editMath(editor, 'inline', pos),
      }),
      MarginBlockMath.configure({
        katexOptions: { throwOnError: false, displayMode: true },
        onClick: (_node, pos) => editMath(editor, 'block', pos),
      }),
      FrontMatter,
      HtmlBlock,
      HtmlInline,
      FootnoteRef,
      FootnoteDef,
      Find,
      MarginKeys,
      PlainCode,
      MarkdownLinks,
      SlashCommands,
      Markdown.configure({ markedOptions: { gfm: true } } as any),
    ],
    editorProps: {
      attributes: { spellcheck: 'true', class: 'prose' },
    },
  })
  installMinimalEscaping(editor)
  return editor
}

// ---------------------------------------------------------------------------
// Commands (called by the native toolbar and menus)

export function runCommand(editor: Editor, name: string, args: any = {}): boolean {
  const c = () => editor.chain().focus()
  switch (name) {
    case 'bold': return c().toggleBold().run()
    case 'italic': return c().toggleItalic().run()
    case 'strike': return c().toggleStrike().run()
    case 'code': return c().toggleCode().run()
    case 'highlight': return c().toggleHighlight().run()
    case 'link': return editLink(editor), true
    case 'paragraph': return c().setParagraph().run()
    case 'heading': {
      const level = Number(args.level ?? 1)
      return level === 0 ? c().setParagraph().run() : c().toggleHeading({ level: level as any }).run()
    }
    case 'bulletList': return c().toggleBulletList().run()
    case 'orderedList': return c().toggleOrderedList().run()
    case 'taskList': return c().toggleTaskList().run()
    case 'blockquote': return c().toggleBlockquote().run()
    case 'codeBlock': return c().toggleCodeBlock().run()
    case 'mermaid':
      return c()
        .insertContent({ type: 'codeBlock', attrs: { language: 'mermaid' }, content: [{ type: 'text', text: MERMAID_SAMPLE }] })
        .run()
    case 'horizontalRule': return c().setHorizontalRule().run()
    case 'inlineMath': return editMath(editor, 'inline'), true
    case 'blockMath': return editMath(editor, 'block'), true
    case 'table': return c().insertTable({ rows: 3, cols: 3, withHeaderRow: true }).run()
    case 'addRowBefore': return c().addRowBefore().run()
    case 'addRowAfter': return c().addRowAfter().run()
    case 'addColumnBefore': return c().addColumnBefore().run()
    case 'addColumnAfter': return c().addColumnAfter().run()
    case 'deleteRow': return c().deleteRow().run()
    case 'deleteColumn': return c().deleteColumn().run()
    case 'deleteTable': return c().deleteTable().run()
    case 'image': {
      const src = String(args.src ?? '')
      if (!src) return false
      // Dropped files arrive with the drop point; put the caret there first.
      if (typeof args.x === 'number' && typeof args.y === 'number') {
        const hit = editor.view.posAtCoords({ left: args.x, top: args.y })
        if (hit) editor.commands.setTextSelection(hit.pos)
      }
      let name = src.split('/').pop() ?? ''
      try {
        name = decodeURIComponent(name)
      } catch {}
      const alt = args.alt ?? name.replace(/\.[^.]+$/, '')
      const image = { type: 'image', attrs: { src, alt } }
      // On an empty line the image gets its own paragraph and typing continues below it.
      const { $from } = editor.state.selection
      if ($from.parent.type.name === 'paragraph' && $from.parent.content.size === 0) {
        return c().insertContent([{ type: 'paragraph', content: [image] }, { type: 'paragraph' }]).run()
      }
      return c().insertContent(image).run()
    }
    case 'insertText': return c().insertContent(String(args.text ?? '')).run()
    case 'clearFormatting': return c().unsetAllMarks().clearNodes().run()
    case 'undo': return c().undo().run()
    case 'redo': return c().redo().run()
    default: return false
  }
}

/** What the native toolbar should show as active for the current selection. */
export function selectionState(editor: Editor) {
  let heading = 0
  for (let l = 1; l <= 6; l++) if (editor.isActive('heading', { level: l })) heading = l
  return {
    bold: editor.isActive('bold'),
    italic: editor.isActive('italic'),
    strike: editor.isActive('strike'),
    code: editor.isActive('code'),
    highlight: editor.isActive('highlight'),
    link: editor.isActive('link'),
    heading,
    bulletList: editor.isActive('bulletList') && !editor.isActive('taskList'),
    orderedList: editor.isActive('orderedList'),
    taskList: editor.isActive('taskList'),
    blockquote: editor.isActive('blockquote'),
    codeBlock: editor.isActive('codeBlock'),
    table: editor.isActive('table'),
    canUndo: editor.can().undo(),
    canRedo: editor.can().redo(),
  }
}
