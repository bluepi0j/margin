#!/bin/sh
# Rebuilds the web editor (WebEditor/) into Sources/Margin/Resources/Editor.
# Needed only after changing files in WebEditor/; the output is committed.
set -eu
cd "$(dirname "$0")/../WebEditor"
[ -d node_modules ] || npm ci
node build.mjs
