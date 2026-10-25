// A small floating editor used for links, math and code-block languages.
// One popover at a time; Enter applies, Escape cancels, clicking outside applies.

export interface PopoverOptions {
  anchor: DOMRect
  value: string
  placeholder?: string
  multiline?: boolean
  label?: string
  suggestions?: string[]
  /** Return HTML to show under the input as a live preview. */
  preview?: (value: string) => string
  onSubmit: (value: string) => void
  onCancel?: () => void
  /** Optional secondary action (e.g. "Remove link"). */
  secondary?: { title: string; run: () => void }
}

let current: { el: HTMLElement; close: (apply: boolean) => void } | null = null

export function isPopoverOpen() {
  return current !== null
}

export function closePopover(apply = false) {
  current?.close(apply)
}

export function openPopover(opts: PopoverOptions) {
  closePopover(false)

  const el = document.createElement('div')
  el.className = 'popover'
  el.addEventListener('mousedown', e => e.stopPropagation())

  if (opts.label) {
    const label = document.createElement('div')
    label.className = 'popover-label'
    label.textContent = opts.label
    el.appendChild(label)
  }

  const input = document.createElement(opts.multiline ? 'textarea' : 'input') as HTMLInputElement | HTMLTextAreaElement
  input.className = 'popover-input'
  input.value = opts.value
  input.placeholder = opts.placeholder ?? ''
  input.spellcheck = false
  input.setAttribute('autocapitalize', 'off')
  input.setAttribute('autocorrect', 'off')
  if (opts.multiline) (input as HTMLTextAreaElement).rows = Math.min(8, Math.max(2, opts.value.split('\n').length))
  el.appendChild(input)

  if (opts.suggestions?.length) {
    const list = document.createElement('datalist')
    list.id = 'popover-suggestions'
    for (const s of opts.suggestions) {
      const o = document.createElement('option')
      o.value = s
      list.appendChild(o)
    }
    el.appendChild(list)
    input.setAttribute('list', list.id)
  }

  let previewEl: HTMLElement | null = null
  if (opts.preview) {
    previewEl = document.createElement('div')
    previewEl.className = 'popover-preview'
    el.appendChild(previewEl)
    const update = () => {
      previewEl!.innerHTML = opts.preview!(input.value)
    }
    input.addEventListener('input', update)
    update()
  }

  const footer = document.createElement('div')
  footer.className = 'popover-footer'
  const hint = document.createElement('span')
  hint.className = 'popover-hint'
  hint.textContent = opts.multiline ? '⌘↩ Apply · esc Cancel' : '↩ Apply · esc Cancel'
  footer.appendChild(hint)
  if (opts.secondary) {
    const b = document.createElement('button')
    b.className = 'popover-secondary'
    b.textContent = opts.secondary.title
    b.addEventListener('click', () => {
      close(false, true)
      opts.secondary!.run()
    })
    footer.appendChild(b)
  }
  el.appendChild(footer)

  document.body.appendChild(el)

  // Position below the anchor, flipped above if there is no room.
  const width = Math.min(opts.multiline ? 420 : 340, window.innerWidth - 24)
  el.style.width = `${width}px`
  const left = Math.max(12, Math.min(opts.anchor.left, window.innerWidth - width - 12))
  el.style.left = `${left}px`
  const h = el.offsetHeight
  const below = opts.anchor.bottom + 8
  const top = below + h > window.innerHeight - 8 ? Math.max(8, opts.anchor.top - h - 8) : below
  el.style.top = `${top}px`

  let done = false
  function close(apply: boolean, silent = false) {
    if (done) return
    done = true
    document.removeEventListener('mousedown', outside, true)
    el.remove()
    current = null
    if (silent) return
    if (apply) opts.onSubmit(input.value)
    else opts.onCancel?.()
  }
  const outside = (e: MouseEvent) => {
    if (!el.contains(e.target as Node)) close(true)
  }
  document.addEventListener('mousedown', outside, true)

  input.addEventListener('keydown', (e: Event) => {
    const ke = e as KeyboardEvent
    if (ke.key === 'Escape') {
      ke.preventDefault()
      close(false)
    } else if (ke.key === 'Enter' && !ke.isComposing && (!opts.multiline || ke.metaKey)) {
      ke.preventDefault()
      close(true)
    }
    ke.stopPropagation()
  })

  current = { el, close: (apply: boolean) => close(apply) }
  requestAnimationFrame(() => {
    input.focus()
    input.select()
  })
}
