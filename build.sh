#!/bin/bash
# Build, ad-hoc sign, and install Viaduct.app to /Applications.
#
# Why the retry loop: this project lives in an iCloud/fileprovider-synced folder.
# Sync restamps com.apple.FinderInfo onto the bundle root between `xattr -cr` and
# `codesign`, which makes codesign reject the bundle ("detritus not allowed").
# We strip + sign in a loop until we win the race.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REL="$ROOT/build/Build/Products/Release"
APP="$REL/Viaduct.app"
APPEX="$APP/Contents/PlugIns/ViaductExtension.appex"
EXT_ENT="$ROOT/Extension/ViaductExtension.entitlements"
APP_ENT="$ROOT/Viaduct.entitlements"
DEST="/Applications/Viaduct.app"

# Sign with the real Apple Development identity (persists across reboot, unlike ad-hoc).
# Free account = no Developer ID / notarization, so OTHER Macs still warn; on this Mac it's fine.
SIGN_ID="$(security find-identity -v -p codesigning | grep 'Apple Development' | head -1 | grep -oE '[A-F0-9]{40}')"
[ -n "$SIGN_ID" ] || { echo "FAILED: no Apple Development identity found"; exit 1; }

"$ROOT/sync-cli.sh"

echo "==> Building (unsigned, universal)"
rm -rf "$REL"
# See release.sh: without the generic destination xcodebuild builds only this
# Mac's arch, so a local install would never exercise the Intel slice.
xcodebuild -project "$ROOT/Viaduct.xcodeproj" -scheme Viaduct \
  -configuration Release -derivedDataPath "$ROOT/build" \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO >/dev/null

echo "==> Signing ($SIGN_ID, with detritus retry)"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
signed=""
for i in $(seq 1 8); do
  xattr -cr "$APP"
  # Xcode's embed phase strips Sparkle's headers, which its shipped signature
  # still seals — so --verify --deep fails until we re-sign the framework and
  # every nested helper ourselves, inside-out. Same order as release.sh.
  if [ -d "$SPARKLE" ]; then
    for item in "$SPARKLE/Versions/B/XPCServices/"*.xpc \
                "$SPARKLE/Versions/B/Updater.app" \
                "$SPARKLE/Versions/B/Autoupdate"; do
      [ -e "$item" ] || continue
      codesign --force --sign "$SIGN_ID" --timestamp=none --options runtime "$item" 2>/dev/null || true
    done
    codesign --force --sign "$SIGN_ID" --timestamp=none --options runtime "$SPARKLE" 2>/dev/null || true
  fi
  codesign --force --sign "$SIGN_ID" --timestamp=none --options runtime \
    --entitlements "$EXT_ENT" "$APPEX" 2>/dev/null || true
  xattr -cr "$APP"
  if codesign --force --sign "$SIGN_ID" --timestamp=none --options runtime \
       --entitlements "$APP_ENT" "$APP" 2>/dev/null \
     && codesign --verify --deep "$APP" 2>/dev/null; then
    signed="$i"; break
  fi
done
[ -n "$signed" ] || { echo "FAILED: could not sign after 8 tries (detritus race)"; exit 1; }
echo "    signed on try $signed"

echo "==> Installing to $DEST"
killall Viaduct 2>/dev/null || true
rm -rf "$DEST"
ditto "$APP" "$DEST"
codesign --verify --deep "$DEST"

# Delete the build-dir copy: it's a second signed bundle with the same bundle
# id, and Safari/pluginkit can bind the extension to IT instead of $DEST —
# then the next rebuild rm-rf's it and the store-page progress bridge dies
# with a wedged appex. One bundle id, one bundle on disk.
rm -rf "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$DEST" >/dev/null 2>&1 || true
echo "==> Done: $DEST"
