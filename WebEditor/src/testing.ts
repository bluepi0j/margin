// Entry for node tests (bundled by build.mjs --test). Needs a DOM (happy-dom).
export { createEditor, runCommand, selectionState } from './editor'
export { parseMarkdown, serializeMarkdown, escapeText, splitFrontMatter } from './markdown'
export { blockOffsets, sourceOffset, docPosition } from './sourcemap'
export { computeHunks, diffHunks, revertHunk, setDiffBase, wordDiff, tokens, matches } from './diff'
