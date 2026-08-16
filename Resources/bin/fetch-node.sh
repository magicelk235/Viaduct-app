#!/bin/bash
# Download a self-contained official node binary to bundle inside the .app, so end
# users need NOT install Node themselves. Homebrew's node is a thin launcher linked
# against ~25 /opt/homebrew dylibs — useless off the build machine; nodejs.org ships
# a single statically-self-contained bin/node (links only /usr/lib + /System). That's
# the one we bundle.
#
# nodejs.org has no universal build, so we lipo the arm64 and x64 downloads into one
# fat binary. Always both slices, regardless of what this build's ARCHS says: a
# universal .app has to carry a node that runs on either chip, and a single-arch dev
# build is happy to run a fat one. lipo copies each slice verbatim, so both keep the
# Node.js Foundation Developer ID signature they shipped with — nothing to re-sign.
#
# Run by the Xcode "Fetch Node" build phase (idempotent: skips if already present and
# the right version). The result, Resources/bin/node, is gitignored and produced at build.
set -euo pipefail

# Pin an LTS. Bump deliberately; the CLI needs >=18 (package.json engines).
NODE_VER="${VIADUCT_NODE_VERSION:-v20.18.1}"

DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$DIR/node"

# Skip the download if we already have the pinned version with both slices. The
# binary itself is the state — no marker file to fall out of sync with it.
if [ -x "$DEST" ] && "$DEST" --version 2>/dev/null | grep -qx "$NODE_VER" \
   && lipo -archs "$DEST" 2>/dev/null | grep -qw arm64 \
   && lipo -archs "$DEST" 2>/dev/null | grep -qw x86_64; then
  echo "fetch-node: $NODE_VER (universal) already present — skipping."
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

for NODE_ARCH in arm64 x64; do
  URL="https://nodejs.org/dist/${NODE_VER}/node-${NODE_VER}-darwin-${NODE_ARCH}.tar.gz"
  echo "fetch-node: downloading $URL"
  curl -fsSL "$URL" -o "$work/$NODE_ARCH.tar.gz"
  # Extract just the binary — we don't ship npm/npx/headers, only the runtime.
  tar xzf "$work/$NODE_ARCH.tar.gz" -C "$work" --strip-components=2 \
    "node-${NODE_VER}-darwin-${NODE_ARCH}/bin/node"
  mv "$work/node" "$work/node-$NODE_ARCH"
done

lipo -create "$work/node-arm64" "$work/node-x64" -output "$work/node-universal"
mkdir -p "$DIR"
mv "$work/node-universal" "$DEST"
chmod 0755 "$DEST"
echo "fetch-node: installed $("$DEST" --version) ($(lipo -archs "$DEST")) → $DEST"
