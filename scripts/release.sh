#!/bin/sh
# Packages a release into dist/release/: the app zip, Sparkle's update feed
# (appcast.xml) and the Homebrew cask. The release workflow
# (.github/workflows/release.yml) runs this; it also works locally.
#
#   scripts/release.sh <version> <build-number> [notes.md]
#
# Signs the zip with the Sparkle EdDSA key from $SPARKLE_KEY_FILE, or else
# from the login Keychain (account "margin", made by Sparkle's generate_keys).
set -eu
VERSION="${1:?version, e.g. 1.2.0}"
BUILD="${2:?build number, must grow with every release}"
NOTES="${3:-}"
REPO="bluepi0j/margin"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/dist/release"
cd "$ROOT"

echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "version must look like 1.2.0"; exit 1; }

# The version goes into Resources/Info.plist (the workflow commits it).
plutil -replace CFBundleShortVersionString -string "$VERSION" Resources/Info.plist
plutil -replace CFBundleVersion -string "$BUILD" Resources/Info.plist
scripts/build-app.sh release --universal

rm -rf "$OUT" && mkdir -p "$OUT"
ZIP="Margin-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent dist/Margin.app "$OUT/$ZIP"

SIGN="$(find .build/artifacts -path '*Sparkle*/bin/sign_update' | head -1)"
if [ -n "${SPARKLE_KEY_FILE:-}" ]; then
    SIGNATURE="$("$SIGN" --ed-key-file "$SPARKLE_KEY_FILE" "$OUT/$ZIP")"
else
    SIGNATURE="$("$SIGN" --account margin "$OUT/$ZIP")"
fi

# Release notes for the update window: plain text, shown as written.
NOTES_HTML="$( [ -n "$NOTES" ] && sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' "$NOTES" || true )"
cat > "$OUT/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Margin</title>
    <item>
      <title>Margin $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<pre style="font: 13px -apple-system; white-space: pre-wrap">$NOTES_HTML</pre>]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/$ZIP" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
EOF

SHA="$(shasum -a 256 "$OUT/$ZIP" | cut -d' ' -f1)"
cat > "$OUT/margin.rb" <<EOF
cask "margin" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$REPO/releases/download/v#{version}/Margin-#{version}.zip"
  name "Margin"
  desc "Lightweight Markdown editor"
  homepage "https://github.com/$REPO"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Margin.app"

  # Margin is not notarized (no Apple Developer ID), so macOS would refuse to
  # open it the first time; Homebrew installs are trusted, so lift that.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Margin.app"]
  end

  zap trash: [
    "~/Library/Application Support/Margin",
    "~/Library/Caches/app.margin.Margin",
    "~/Library/HTTPStorages/app.margin.Margin",
    "~/Library/Preferences/app.margin.Margin.plist",
    "~/Library/Saved Application State/app.margin.Margin.savedState",
    "~/Library/WebKit/app.margin.Margin",
  ]
end
EOF

echo "Release files in $OUT:"
ls -l "$OUT"
