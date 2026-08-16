#!/bin/bash
# Refresh Resources/cli from the published npm package.
#
# The app ships a copy of the viaduct CLI so a fresh install can convert before
# it has ever talked to npm. That copy is checked in, so nothing updates it on
# its own: it sat at 1.0.0 while npm was on 1.9.x, and every first run used the
# stale one. Signing quietly regressed as a result (1.0.0 only reads the team
# from Xcode's preference cache and has no keychain fallback), so this runs from
# build.sh and release.sh — the bundle can't go stale without the build noticing.
#
# Usage: ./sync-cli.sh [version]     # default: latest
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PKG="@magicelk235/viaduct"
WANT="${1:-latest}"
DEST="$ROOT/Resources/cli"

command -v npm >/dev/null || { echo "FAILED: npm not found"; exit 1; }

VERSION="$(npm view "$PKG@$WANT" version)"
[ -n "$VERSION" ] || { echo "FAILED: could not resolve $PKG@$WANT"; exit 1; }

HAVE="$(cat "$DEST/version.txt" 2>/dev/null || echo none)"
if [ "$HAVE" = "$VERSION" ]; then
  echo "==> Bundled CLI already at $VERSION"
  exit 0
fi

echo "==> Syncing bundled CLI $HAVE -> $VERSION"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

TARBALL="$(cd "$WORK" && npm pack "$PKG@$VERSION" --silent)"
tar xzf "$WORK/$TARBALL" -C "$WORK"
[ -f "$WORK/package/dist/cli.js" ] || { echo "FAILED: dist/cli.js missing in tarball"; exit 1; }

# Replace wholesale. Files dropped between versions must not linger, and the
# staged output of a stray conversion must not ride along into the bundle.
rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$WORK/package/dist" "$DEST/dist"
cp "$WORK/package/package.json" "$DEST/package.json"
printf '%s' "$VERSION" > "$DEST/version.txt"

echo "==> Bundled CLI now $VERSION ($(find "$DEST" -type f | wc -l | tr -d ' ') files)"
