#!/bin/bash
# Assemble the Add to Firefox add-on in Resources/firefox/store-button: its own manifest,
# transport and background from Firefox/store-button, plus the page script and icon it
# shares with the Safari extension.
#
# Run by the Xcode "Build Store Button" phase. Replaces only the store-button folder:
# Resources/firefox also holds persist.mjs, which build-persist.sh owns.
set -euo pipefail

ROOT="${SRCROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
OUT="$ROOT/Resources/firefox/store-button"

# By hand, outside Xcode, take the version from project.yml.
VERSION="${MARKETING_VERSION:-$(/usr/bin/sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/p' "$ROOT/project.yml")}"
[ -n "$VERSION" ] || { echo "error: build-store-button: no MARKETING_VERSION"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"
cp "$ROOT/Firefox/store-button/manifest.json" \
   "$ROOT/Firefox/store-button/transport.js" \
   "$ROOT/Firefox/store-button/background.js" \
   "$ROOT/Extension/Resources/content.js" \
   "$ROOT/Extension/Resources/icon.png" \
   "$OUT/"

# Persist only reloads an add-on whose version changed, so this stamp is what gets a new
# page script to people who already have the button. The checked-in manifest keeps 0.0.0.
manifest="$OUT/manifest.json"
/usr/bin/sed -i '' -E "s/(\"version\"[[:space:]]*:[[:space:]]*\")[^\"]*\"/\1$VERSION\"/" "$manifest"
grep -q "\"version\": \"$VERSION\"" "$manifest" \
  || { echo "error: build-store-button: manifest version not stamped in $manifest"; exit 1; }
echo "build-store-button: $VERSION → $OUT"
