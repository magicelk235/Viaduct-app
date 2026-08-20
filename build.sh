#!/bin/bash
# Build, sign, and install a universal Viaduct.app to /Applications for local testing.
#
# Signing happens in /tmp, not in the repo: this project lives in a fileprovider-synced
# folder and sync restamps com.apple.FinderInfo onto the bundle root mid-sign, which
# codesign rejects ("detritus not allowed"). /tmp isn't synced, so it's a clean one-shot.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REL="$ROOT/build/Build/Products/Release"
WORK="/private/tmp/viaduct-dev"
APP="$WORK/Viaduct.app"
APPEX="$APP/Contents/PlugIns/ViaductExtension.appex"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
EXT_ENT="$ROOT/Extension/ViaductExtension.entitlements"
APP_ENT="$ROOT/Viaduct.entitlements"
DEST="/Applications/Viaduct.app"

# Sign with the real Apple Development identity (persists across reboot, unlike ad-hoc).
# Free account = no Developer ID / notarization, so OTHER Macs still warn; on this Mac it's fine.
SIGN_ID="$(security find-identity -v -p codesigning | grep 'Apple Development' | head -1 | grep -oE '[A-F0-9]{40}')"
[ -n "$SIGN_ID" ] || { echo "FAILED: no Apple Development identity found"; exit 1; }

echo "==> Building (unsigned, universal)"
rm -rf "$REL"
# generic/platform=macOS is load-bearing: without it xcodebuild resolves the run
# destination to "My Mac", pins ARCHS to this machine's arch, and quietly drops
# the Intel slice — so a local install would never exercise it.
xcodebuild -project "$ROOT/Viaduct.xcodeproj" -scheme Viaduct \
  -configuration Release -derivedDataPath "$ROOT/build" \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO >/dev/null

echo "==> Staging to $WORK for signing"
rm -rf "$WORK" && mkdir -p "$WORK"
ditto "$REL/Viaduct.app" "$APP"

# Sign inside-out. Xcode's embed phase strips Sparkle's headers, which the
# framework's shipped signature still seals, so --verify --deep fails until we
# re-sign the framework and each nested helper ourselves. Same order as release.sh.
echo "==> Signing ($SIGN_ID)"
xattr -cr "$APP"
if [ -d "$SPARKLE" ]; then
  for item in "$SPARKLE/Versions/B/XPCServices/"*.xpc \
              "$SPARKLE/Versions/B/Updater.app" \
              "$SPARKLE/Versions/B/Autoupdate"; do
    [ -e "$item" ] || continue   # XPC services only ship in the sandboxed variant
    codesign --force --sign "$SIGN_ID" --timestamp=none --options runtime "$item"
  done
  codesign --force --sign "$SIGN_ID" --timestamp=none --options runtime "$SPARKLE"
fi
codesign --force --sign "$SIGN_ID" --timestamp=none --options runtime \
  --entitlements "$EXT_ENT" "$APPEX"
codesign --force --sign "$SIGN_ID" --timestamp=none --options runtime \
  --entitlements "$APP_ENT" "$APP"
codesign --verify --deep "$APP"

echo "==> Installing to $DEST"
killall Viaduct 2>/dev/null || true
rm -rf "$DEST"
ditto "$APP" "$DEST"
codesign --verify --deep "$DEST"

# Delete both loose copies: a second signed bundle with the same bundle id lets
# Safari/pluginkit bind the extension to IT instead of $DEST — then the next
# rebuild rm-rf's it and the store-page progress bridge dies with a wedged appex.
# One bundle id, one bundle on disk.
rm -rf "$REL/Viaduct.app" "$WORK"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$DEST" >/dev/null 2>&1 || true
echo "==> Done: $DEST ($(lipo -archs "$DEST/Contents/MacOS/Viaduct"))"
