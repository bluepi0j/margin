#!/bin/sh
# Builds dist/Margin.app.  Usage: scripts/build-app.sh [debug|release]
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
# SwiftPM needs the full Xcode toolchain (for XCTest and the macOS SDK).
if [ -z "${DEVELOPER_DIR:-}" ] && ! xcodebuild -version >/dev/null 2>&1; then
    XCODE="$(ls -d /Applications/Xcode*.app 2>/dev/null | grep -v -i 'copilot\|xcodes.app' | sort -V | tail -1 || true)"
    [ -n "$XCODE" ] && export DEVELOPER_DIR="$XCODE/Contents/Developer"
fi

cd "$ROOT"
swift build -c "$CONFIG" --product Margin
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="$ROOT/dist/Margin.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Margin" "$APP/Contents/MacOS/Margin"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp -R "$ROOT/Sources/Margin/Resources/Editor" "$APP/Contents/Resources/Editor"
# Resources of the native editor's packages (highlight.js, math fonts).
for bundle in "$BIN"/*.bundle; do
    case "$(basename "$bundle")" in Margin_Margin.bundle) ;; *) cp -R "$bundle" "$APP/Contents/Resources/" ;; esac
done
# The native editor renders formulas with Latin Modern only; drop SwiftMath's other fonts.
find "$APP/Contents/Resources/SwiftMath_SwiftMath.bundle" -type f \( -name '*.otf' -o -name '*.plist' -o -name '*.py' \) \
    ! -name 'latinmodern-math.*' ! -name 'Info.plist' -delete 2>/dev/null || true
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
