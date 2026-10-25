#!/bin/sh
# Runs all automated tests: Swift core logic + editor Markdown round trips.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "${DEVELOPER_DIR:-}" ] && ! xcodebuild -version >/dev/null 2>&1; then
    XCODE="$(ls -d /Applications/Xcode*.app 2>/dev/null | grep -v -i 'copilot\|xcodes.app' | sort -V | tail -1 || true)"
    [ -n "$XCODE" ] && export DEVELOPER_DIR="$XCODE/Contents/Developer"
fi
cd "$ROOT" && swift test
cd "$ROOT/WebEditor" && node build.mjs --test && node --test 'test/*.test.mjs'
