// Ink-brush drawing helpers: strokes whose width swells and tapers like a
// brush, blobs with ragged edges, and filters for wet edges and dry-brush.

// Catmull-Rom through points → dense samples.
function spline(pts, n = 24) {
  const out = []
  for (let i = 0; i < pts.length - 1; i++) {
    const p0 = pts[Math.max(0, i - 1)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[Math.min(pts.length - 1, i + 2)]
    for (let k = 0; k < n; k++) {
      const t = k / n, t2 = t * t, t3 = t2 * t
      out.push([0, 1].map(j => 0.5 * ((2 * p1[j]) + (-p0[j] + p2[j]) * t + (2 * p0[j] - 5 * p1[j] + 4 * p2[j] - p3[j]) * t2 + (-p0[j] + 3 * p1[j] - 3 * p2[j] + p3[j]) * t3)))
    }
  }
  out.push(pts[pts.length - 1])
  return out
}

// A brush stroke: width follows a press–release profile (thin, full, thin).
// `w` = full width; `start`/`end` = how thin the ends get (0..1 of w).
function stroke(pts, w, { start = 0.15, end = 0.05, press = 0.25 } = {}) {
  const s = spline(pts)
  const left = [], right = []
  for (let i = 0; i < s.length; i++) {
    const t = i / (s.length - 1)
    const a = s[Math.max(0, i - 1)], b = s[Math.min(s.length - 1, i + 1)]
    let dx = b[0] - a[0], dy = b[1] - a[1]
    const len = Math.hypot(dx, dy) || 1
    dx /= len; dy /= len
    const ramp = t < press ? start + (1 - start) * Math.sin((t / press) * Math.PI / 2)
      : 1 - (1 - end) * Math.pow((t - press) / (1 - press), 2.2)
    const half = (w / 2) * ramp
    left.push([s[i][0] - dy * half, s[i][1] + dx * half])
    right.push([s[i][0] + dy * half, s[i][1] - dx * half])
  }
  const all = left.concat(right.reverse())
  return 'M ' + all.map(p => p.map(v => v.toFixed(1)).join(' ')).join(' L ') + ' Z'
}

// A filled blob around a centre, radius wobbling a little.
function blob(cx, cy, rx, ry, rot = 0, wobble = 0.08, seed = 1) {
  const pts = []
  let r = seed
  const rand = () => (r = (r * 16807) % 2147483647) / 2147483647
  const n = 14, phase = rand() * 6
  for (let i = 0; i < n; i++) {
    const a = (i / n) * Math.PI * 2
    const k = 1 + wobble * (Math.sin(a * 3 + phase) * 0.6 + (rand() - 0.5))
    const x = Math.cos(a) * rx * k, y = Math.sin(a) * ry * k
    pts.push([cx + x * Math.cos(rot) - y * Math.sin(rot), cy + x * Math.sin(rot) + y * Math.cos(rot)])
  }
  const s = spline(pts.concat([pts[0], pts[1]]), 10).slice(0, -10)
  return 'M ' + s.map(p => p.map(v => v.toFixed(1)).join(' ')).join(' L ') + ' Z'
}

// Filters: "wet" roughens edges; "dry" adds streaks of paper through the ink.
const defs = `
<filter id="wet" x="-5%" y="-5%" width="110%" height="110%">
  <feTurbulence type="fractalNoise" baseFrequency="0.035" numOctaves="3" seed="4" result="n"/>
  <feDisplacementMap in="SourceGraphic" in2="n" scale="9" xChannelSelector="R" yChannelSelector="G"/>
</filter>
<filter id="dry" x="-5%" y="-5%" width="110%" height="110%">
  <feTurbulence type="fractalNoise" baseFrequency="0.008 0.11" numOctaves="2" seed="9" result="streak"/>
  <feColorMatrix in="streak" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 -7 4.9" result="mask"/>
  <feComposite in="SourceGraphic" in2="mask" operator="in" result="streaked"/>
  <feTurbulence type="fractalNoise" baseFrequency="0.035" numOctaves="3" seed="2" result="n"/>
  <feDisplacementMap in="streaked" in2="n" scale="8" xChannelSelector="R" yChannelSelector="G"/>
</filter>`

module.exports = { stroke, blob, defs, spline }
