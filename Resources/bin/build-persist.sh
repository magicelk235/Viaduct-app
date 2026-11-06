#!/bin/bash
# Bundle persist (the private c2f-persist checkout) and the lavaduct modules it imports into one file,
# Resources/firefox/persist.mjs, which the bundled node runs. lavaduct is pinned exactly
# in persist's package.json, so the app carries the version persist's tests ran on.
#
# Run by the Xcode "Build Persist" phase, right after "Fetch Node". Skips the bundle when
# persist.mjs is newer than everything it's built from. Writes only persist.mjs: the
# store button's build owns Resources/firefox/store-button.
set -euo pipefail

ROOT="${SRCROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
PERSIST="${PERSIST_DIR:-$ROOT/../c2f-persist}"
OUT="$ROOT/Resources/firefox/persist.mjs"

# Xcode runs build phases with a bare PATH; npm comes from Homebrew or the nodejs.org installer.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Persist's source lives in a private repo. A checkout of this public repo without it
# builds an app without Firefox support; release.sh refuses to ship that build.
# Xcode copies Resources/firefox whether or not it holds anything, so the folder must
# exist, and an earlier build's persist.mjs must not ship in a build without persist.
if [ ! -f "$PERSIST/package.json" ]; then
  echo "warning: build-persist: no persist checkout at $PERSIST. This build has no Firefox support. Set PERSIST_DIR to build it."
  mkdir -p "$(dirname "$OUT")"
  rm -f "$OUT"
  exit 0
fi
command -v npm >/dev/null || { echo "error: build-persist: npm not found. Install Node.js (brew install node)."; exit 1; }
cd "$PERSIST"
# npm ci only when the lockfile changed since the last install.
if [ ! -f node_modules/.package-lock.json ] || [ package-lock.json -nt node_modules/.package-lock.json ]; then
  npm ci --no-audit --no-fund
fi
if [ -f "$OUT" ] && [ -z "$(find src scripts/bundle.mjs package.json package-lock.json tsconfig.json -newer "$OUT" -print -quit)" ]; then
  echo "build-persist: $OUT is up to date — skipping."
  exit 0
fi
mkdir -p "$(dirname "$OUT")"
node scripts/bundle.mjs "$OUT"
echo "build-persist: $(node "$OUT" --version) → $OUT"
