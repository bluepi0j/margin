// Bundles the editor page into the app's resources.
//   node build.mjs          -> ../Sources/Margin/Resources/Editor (minified)
//   node build.mjs --test   -> test/.build/core.mjs (for node tests)
import * as esbuild from 'esbuild'
import fs from 'node:fs'
import path from 'node:path'

const here = path.dirname(new URL(import.meta.url).pathname)
const outdir = path.resolve(here, '../Sources/Margin/Resources/Editor')
const testOnly = process.argv.includes('--test')

// KaTeX ships woff2, woff and ttf for every font; WebKit only needs woff2.
const katexWoff2Only = {
  name: 'katex-woff2-only',
  setup(build) {
    build.onLoad({ filter: /katex\.min\.css$/ }, async args => ({
      contents: (await fs.promises.readFile(args.path, 'utf8')).replace(/,url\([^)]+\.(?:woff|ttf)\) format\("(?:woff|truetype)"\)/g, ''),
      loader: 'css',
    }))
  },
}

await esbuild.build({
  entryPoints: [path.join(here, 'src/testing.ts')],
  bundle: true,
  format: 'esm',
  platform: 'node',
  outfile: path.join(here, 'test/.build/core.mjs'),
  logLevel: 'warning',
})

// The whole page (doc switching, saving protocol), for node tests.
await esbuild.build({
  entryPoints: [path.join(here, 'src/main.ts')],
  bundle: true,
  format: 'esm',
  platform: 'node',
  outfile: path.join(here, 'test/.build/page.mjs'),
  loader: { '.css': 'empty' },
  logLevel: 'warning',
})

if (!testOnly) {
  fs.rmSync(outdir, { recursive: true, force: true })
  await esbuild.build({
    entryPoints: { editor: path.join(here, 'src/main.ts') },
    bundle: true,
    minify: true,
    format: 'iife',
    target: 'safari17',
    outdir,
    loader: { '.woff2': 'file' },
    assetNames: 'fonts/[name]',
    legalComments: 'none',
    plugins: [katexWoff2Only],
    logLevel: 'warning',
  })
  // Mermaid renderer: its own file so it only loads when a diagram appears.
  await esbuild.build({
    entryPoints: { mermaid: path.join(here, 'src/mermaid-entry.ts') },
    bundle: true,
    minify: true,
    format: 'iife',
    target: 'safari17',
    outdir,
    legalComments: 'none',
    logLevel: 'warning',
  })
  fs.copyFileSync(path.join(here, 'index.html'), path.join(outdir, 'index.html'))
  const size = dir => fs.readdirSync(dir, { withFileTypes: true }).reduce((n, e) => n + (e.isDirectory() ? size(path.join(dir, e.name)) : fs.statSync(path.join(dir, e.name)).size), 0)
  console.log(`editor bundle: ${(size(outdir) / 1024).toFixed(0)} KB -> ${path.relative(process.cwd(), outdir)}`)
}
