// The app icon: a black ink cat asleep on a notebook page, its tail sweeping
// across the paper like the last stroke of a pen. Writes Resources/AppIcon.svg; scripts/make-icon.swift turns
// that into AppIcon.icns.  Run: node scripts/icon/cat.cjs [curl|underline|drop]
const fs = require('fs')
const { stroke, blob, defs } = require('./ink.cjs')
const INK = '#141414', PAPER = '#fbfaf7'

function tile(body) {
  return `<svg viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">
<defs>${defs}
  <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#000" flood-opacity="0.22"/></filter>
  <clipPath id="tile"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>
</defs>
<rect x="100" y="100" width="824" height="824" rx="185" fill="${PAPER}" filter="url(#shadow)"/>
<g clip-path="url(#tile)">${body}</g>
<rect x="100" y="100" width="824" height="824" rx="185" fill="none" stroke="#000" stroke-opacity="0.07" stroke-width="2"/>
</svg>`
}
const ink = (d, f = 'wet', fill = INK) => `<path d="${d}" fill="${fill}" filter="url(#${f})"/>`

// A pointed ear: a small triangle with soft corners.
function ear(tip, baseL, baseR) {
  return `M ${baseL[0]} ${baseL[1]} Q ${(baseL[0] + tip[0]) / 2 - 6} ${(baseL[1] + tip[1]) / 2} ${tip[0]} ${tip[1]} Q ${(tip[0] + baseR[0]) / 2 + 8} ${(tip[1] + baseR[1]) / 2} ${baseR[0]} ${baseR[1]} Z`
}

// Tail options: where it drops over the page edge and how it ends.
const TAILS = {
  // One relaxed curl at the end, the way a cat's tail rests.
  curl: [stroke([[640, 420], [698, 452], [728, 512], [722, 582], [694, 622], [662, 618], [656, 592], [678, 582]], 40, { start: 0.9, end: 0.4, press: 0.08 })],
  // Lies across the page and tapers off like the end of a pen line.
  underline: [stroke([[640, 420], [700, 452], [708, 505], [670, 552], [585, 585], [470, 598], [370, 594], [300, 584]], 40, { start: 0.9, end: 0.08, press: 0.06 })],
  // A soft S over the edge, the tip touching the first line, with the dot it left.
  drop: [stroke([[640, 420], [700, 458], [694, 530], [652, 584], [664, 640], [712, 668]], 40, { start: 0.9, end: 0.3, press: 0.08 }),
         blob(742, 690, 13, 11, 0, 0.1, 21)],
}

function cat(tail = TAILS.underline) {
  const out = []
  // The notebook page, tilted a touch, filling the lower part of the tile.
  out.push(`<g transform="rotate(-5 512 690)">`)
  out.push(`<rect x="215" y="455" width="620" height="520" fill="#ffffff"/>`)
  out.push(ink(stroke([[212, 460], [520, 452], [838, 458]], 14, { start: 0.6, end: 0.5, press: 0.3 })))     // top edge
  out.push(ink(stroke([[214, 452], [210, 700], [216, 990]], 13, { start: 0.7, end: 0.8, press: 0.2 })))     // left edge
  out.push(ink(stroke([[836, 455], [842, 700], [838, 990]], 12, { start: 0.7, end: 0.8, press: 0.2 })))     // right edge
  for (const [y, x2] of [[760, 760], [840, 700], [920, 740]]) {
    out.push(ink(stroke([[290, y], [520, y - 3], [x2, y + 2]], 7, { start: 0.5, end: 0.3, press: 0.3 }), 'wet', '#c9c6bf'))
  }
  out.push(`</g>`)

  // The cat, lying along the top edge of the page (a loaf) — one ink pass, so
  // head, body, ears, paw and tail merge without seams.
  const cat = [
    blob(470, 405, 190, 92, -0.08, 0.05, 3),                 // body
    blob(290, 360, 108, 98, 0, 0.05, 5),                     // head
    ear([218, 215], [200, 330], [282, 282]), ear([350, 220], [300, 280], [380, 318]),
    blob(352, 470, 52, 34, 0.1, 0.06, 9),                    // front paw over the edge
    ...tail,
  ]
  out.push(`<g filter="url(#wet)" fill="${INK}">${cat.map(d => `<path d="${d}"/>`).join('')}</g>`)
  // Sleepy closed eyes: thin paper-white arcs.
  out.push(`<g fill="none" stroke="${PAPER}" stroke-width="9" stroke-linecap="round">
    <path d="M 228 362 Q 250 382 272 362"/><path d="M 310 360 Q 332 380 354 360"/></g>`)
  return tile(out.join('\n'))
}
const out = require('path').join(__dirname, '../../Resources/AppIcon.svg')
fs.writeFileSync(out, cat(TAILS[process.argv[2]] ?? TAILS.underline))
module.exports = { cat, TAILS }
console.log('wrote ' + out)
