// The outline rail: a column of ticks down the left edge of the page, one per
// H1–H3 with a faint gradation between, so the shape of the document is
// visible while you read. Ticks swell around the pointer (or, at rest, around
// where you are); hovering shows a card naming the section, clicking jumps
// there, and dragging scrubs through the document.
// The idea is from Imark (github.com/migsilva89/imark, MIT).

const PITCH = [6, 11]        // px per row (a heading plus its gradation is two rows)
const SPAN = 0.7             // how much of the viewport the rail may fill
const SIGMA = 1.15           // width of the swell, in headings
const GROW = 26              // how much the tick at the centre grows
const MINOR_GROW = 8
const MIN_GUTTER = 64        // hide when the margin beside the text is narrower

interface Row {
  el: HTMLElement
  heading: number
  minor: boolean
  level: number
  dash: HTMLElement
}

export class OutlineRail {
  private root = document.createElement('nav')
  private card = document.createElement('aside')
  private rows: Row[] = []
  private headings: HTMLElement[] = []
  private hover: number | null = null
  private here = 0
  enabled = true

  /** `page` gives the rich-text element while it is showing, else null. */
  constructor(private page: () => HTMLElement | null) {
    this.root.className = 'rail'
    this.root.setAttribute('aria-hidden', 'true')
    this.card.className = 'rail-card'
    document.body.append(this.root, this.card)

    // Jump on press, scrub while the button is held. WebKit sometimes drops
    // the release, so "held" is read from `buttons` rather than tracked from
    // pointerup.
    this.root.addEventListener('pointerdown', (e) => {
      e.preventDefault()
      this.hover = this.rowAt(e.clientY)
      this.jump(this.hover, true)
      this.paint()
      this.showCard()
    })
    this.root.addEventListener('pointermove', (e) => {
      this.hover = this.rowAt(e.clientY)
      const scrubbing = (e.buttons & 1) === 1
      this.root.classList.toggle('is-scrubbing', scrubbing)
      if (scrubbing) this.jump(this.hover, false)
      this.paint()
      this.showCard()
    })
    this.root.addEventListener('pointerleave', () => {
      this.hover = null
      this.root.classList.remove('is-scrubbing')
      this.card.classList.remove('is-visible')
      this.paint()
    })
    window.addEventListener('scroll', () => this.track(), { passive: true })
    window.addEventListener('resize', () => this.rebuild())
  }

  /** Re-reads the headings; call after the document or the tab changes. */
  rebuild() {
    const page = this.page()
    const all = page && this.enabled ? [...page.querySelectorAll<HTMLElement>('h1, h2, h3')] : []
    // More headings than fit at the tightest pitch: sample them evenly, so the
    // rail stays proportional to the whole document instead of being cut off.
    const capacity = Math.max(3, Math.floor(((window.innerHeight * 0.9) / PITCH[0] + 1) / 2))
    this.headings = all.length <= capacity ? all
      : Array.from({ length: capacity }, (_, i) => all[Math.floor((i * all.length) / capacity)])
    const gutter = page ? page.getBoundingClientRect().left : 0
    this.root.replaceChildren()
    this.rows = []
    if (this.headings.length < 3 || gutter < MIN_GUTTER) {
      this.root.hidden = true
      this.card.classList.remove('is-visible')
      return
    }
    this.root.hidden = false
    const rowCount = this.headings.length * 2 - 1
    const pitch = Math.min(PITCH[1], Math.max(PITCH[0], (window.innerHeight * SPAN) / rowCount))
    this.root.style.setProperty('--rail-row', `${pitch}px`)
    this.headings.forEach((h, i) => {
      this.add(i, false, Number(h.tagName[1]))
      if (i < this.headings.length - 1) this.add(i, true, 0)
    })
    this.track()
  }

  private add(heading: number, minor: boolean, level: number) {
    const el = document.createElement('span')
    el.className = minor ? 'rail-tick minor' : `rail-tick level-${level}`
    const dash = document.createElement('i')
    el.append(dash)
    this.root.append(el)
    this.rows.push({ el, heading, minor, level, dash })
  }

  /** At rest the swell follows the heading you are reading under. */
  private track() {
    if (!this.headings.length) return
    let current = 0
    const line = 80
    this.headings.forEach((h, i) => {
      if (h.getBoundingClientRect().top <= line) current = i
    })
    this.here = current * 2
    if (this.hover === null) this.paint()
  }

  private rowAt(y: number) {
    const first = this.rows[0]?.el.getBoundingClientRect()
    if (!first) return 0
    const pitch = first.height || 1
    return Math.max(0, Math.min(this.rows.length - 1, Math.floor((y - first.top) / pitch)))
  }

  private paint() {
    const centre = this.hover ?? this.here
    this.rows.forEach((row, i) => {
      const weight = Math.exp(-(((i - centre) / 2) ** 2) / (2 * SIGMA * SIGMA))
      const base = row.minor ? 4 : 8 + Math.max(0, 3 - row.level) * 3
      const rest = row.minor ? 0.14 : 0.3 + Math.max(0, 3 - row.level) * 0.07
      row.dash.style.width = `${base + weight * (row.minor ? MINOR_GROW : GROW)}px`
      row.dash.style.opacity = `${rest + weight * (1 - rest)}`
      row.el.classList.toggle('is-active', i === centre && !row.minor)
    })
  }

  private showCard() {
    if (this.hover === null) return
    const row = this.rows[this.hover]
    const heading = this.headings[row.heading]
    if (!heading) return
    const y = heading.getBoundingClientRect().top + window.scrollY
    const percent = Math.round((y / Math.max(1, document.scrollingElement!.scrollHeight)) * 100)
    let preview = ''
    for (let el = heading.nextElementSibling; el && !/^H[1-6]$/.test(el.tagName) && preview.length < 160; el = el.nextElementSibling) {
      preview += ` ${el.textContent ?? ''}`
    }
    const kicker = document.createElement('em')
    kicker.textContent = `${percent}% in`
    const title = document.createElement('strong')
    title.textContent = heading.textContent || 'Untitled'
    const body = document.createElement('span')
    body.textContent = preview.replace(/\s+/g, ' ').trim()
    this.card.replaceChildren(kicker, title, ...(body.textContent ? [body] : []))
    const rect = row.el.getBoundingClientRect()
    const height = this.card.offsetHeight || 90
    const top = Math.max(12, Math.min(window.innerHeight - height - 12, rect.top + rect.height / 2 - height / 2))
    this.card.style.top = `${top}px`
    this.card.classList.add('is-visible')
  }

  private jump(index: number | null, smooth: boolean) {
    if (index === null) return
    const heading = this.headings[this.rows[index]?.heading ?? -1]
    if (!heading) return
    const top = heading.getBoundingClientRect().top + window.scrollY - 24
    window.scrollTo({ top, behavior: smooth ? 'smooth' : 'auto' })
  }
}
