#!/bin/bash
# Build a DISTRIBUTABLE Viaduct.app + notarized Viaduct.dmg for public download.
#
# Unlike build.sh (Apple Development, this-Mac-only), this signs with the
# Developer ID Application cert + hardened runtime + secure timestamp, then
# notarizes and staples the DMG so it opens cleanly on any Mac (no Gatekeeper
# warning). Requires: `xcrun notarytool store-credentials viaduct-notary ...`
# has been run once (stores Apple ID + team + app-specific password in keychain).
#
# It also produces the Sparkle update channel: a zip of the stapled .app plus a
# signed appcast.xml. Both get attached to the GitHub release alongside the DMG
# (the app's feed URL is .../releases/latest/download/appcast.xml). Signing the
# appcast needs the Sparkle EdDSA private key in the login keychain — see
# `bin/generate_keys` in the resolved Sparkle package.
#
# Usage: ./release.sh          # build, sign, dmg, notarize, staple, appcast
#        ./release.sh --no-notarize   # stop after building the signed dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REL="$ROOT/build/Build/Products/Release"
# Sign in /tmp, NOT in the repo: the repo is iCloud-synced and sync restamps
# com.apple.FinderInfo mid-sign, which codesign rejects ("detritus not allowed").
# /tmp is not synced, so signing is a clean one-shot — no detritus race.
WORK="/private/tmp/viaduct-release"
APP="$WORK/Viaduct.app"
APPEX="$APP/Contents/PlugIns/ViaductExtension.appex"
EXT_ENT="$ROOT/Extension/ViaductExtension.entitlements"
APP_ENT="$ROOT/Viaduct.entitlements"
KEYCHAIN_PROFILE="viaduct-notary"
NOTARIZE=1
[ "${1:-}" = "--no-notarize" ] && NOTARIZE=0

# Developer ID Application identity — the one distributable outside the App Store.
SIGN_ID="$(security find-identity -v -p codesigning | grep 'Developer ID Application' | head -1 | grep -oE '[A-F0-9]{40}')"
[ -n "$SIGN_ID" ] || { echo "FAILED: no Developer ID Application identity found"; exit 1; }
echo "==> Signing identity: $SIGN_ID"

# Never ship a stale bundled CLI — a fresh install runs it before it has ever
# reached npm, so whatever it can't do, the user's first conversion can't do.
"$ROOT/sync-cli.sh"

echo "==> Building (unsigned, universal)"
rm -rf "$REL"
# generic/platform=macOS is load-bearing: without it xcodebuild resolves the run
# destination to "My Mac", which pins ARCHS to this machine's arch and quietly
# ships an arm64-only app. The generic destination honours ARCHS (arm64 x86_64).
xcodebuild -project "$ROOT/Viaduct.xcodeproj" -scheme Viaduct \
  -configuration Release -derivedDataPath "$ROOT/build" \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO >/dev/null

# Copy out of the iCloud-synced repo to /tmp, then sign there (see WORK note above).
echo "==> Staging to $WORK for signing"
rm -rf "$WORK" && mkdir -p "$WORK"
ditto "$REL/Viaduct.app" "$APP"

# Sign inside-out (Sparkle's helpers, then the framework, then the extension,
# then the app). --timestamp (secure, not =none) and --options runtime are
# MANDATORY for notarization. Nothing deep-signs for us here, so every nested
# executable inside Sparkle.framework has to be named explicitly — an unsigned
# one fails notarization for the whole app.
echo "==> Signing with Developer ID"
xattr -cr "$APP"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  for item in "$SPARKLE/Versions/B/XPCServices/"*.xpc \
              "$SPARKLE/Versions/B/Updater.app" \
              "$SPARKLE/Versions/B/Autoupdate"; do
    [ -e "$item" ] || continue   # XPC services only ship in the sandboxed variant
    codesign --force --sign "$SIGN_ID" --timestamp --options runtime "$item"
  done
  codesign --force --sign "$SIGN_ID" --timestamp --options runtime "$SPARKLE"
fi
codesign --force --sign "$SIGN_ID" --timestamp --options runtime \
  --entitlements "$EXT_ENT" "$APPEX"
codesign --force --sign "$SIGN_ID" --timestamp --options runtime \
  --entitlements "$APP_ENT" "$APP"

# Gatekeeper assessment before we even notarize — catches signing mistakes early.
echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Building DMG"
"$ROOT/dmg/make-dmg.sh" "$APP"
OUT="$ROOT/Viaduct.dmg"

# Delete the loose unsigned build product: a duplicate bundle with the installed
# app's bundle id can steal the Safari extension binding from /Applications and
# wedge the store-page progress card. $WORK survives a little longer — the
# Sparkle zip is cut from it once the app carries its notarization ticket.
rm -rf "$REL/Viaduct.app"

if [ "$NOTARIZE" = 0 ]; then
  rm -rf "$WORK"
  echo "==> Done (unnotarized): $OUT"
  echo "    Users WILL hit Gatekeeper warnings. Re-run without --no-notarize to ship."
  echo "    No update zip or appcast — those only make sense for a shippable build."
  exit 0
fi

# Notarize the DMG itself (staple works on the .dmg; users mount and drag).
echo "==> Notarizing (submits to Apple, waits for result — can take a few min)"
xcrun notarytool submit "$OUT" --keychain-profile "$KEYCHAIN_PROFILE" --wait

echo "==> Stapling ticket"
xcrun stapler staple "$OUT"
xcrun stapler validate "$OUT"
# The notarization ticket covers every code item in the submission, so the app
# inside the DMG can be stapled directly from here. Sparkle installs the .app
# out of a zip with no DMG involved, so it needs its own stapled ticket to
# launch on a Mac that happens to be offline.
xcrun stapler staple "$APP"

# --- Sparkle update channel: zip of the stapled app + a signed appcast ---
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DIST="$ROOT/dist"
ZIP="$DIST/Viaduct-$VERSION.zip"
echo "==> Packaging update zip ($VERSION)"
rm -rf "$DIST" && mkdir -p "$DIST"
ditto -c -k --keepParent "$APP" "$ZIP"
rm -rf "$WORK"

# generate_appcast lives in the resolved Sparkle package. It reads the zip,
# signs it with the EdDSA private key from the login keychain, and writes the
# feed. Only this release's zip is in $DIST, so the feed carries a single item —
# all Sparkle needs to offer the update (deltas would need the back catalogue).
GEN="$ROOT/build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
if [ ! -x "$GEN" ]; then
  xcodebuild -project "$ROOT/Viaduct.xcodeproj" -scheme Viaduct \
    -derivedDataPath "$ROOT/build" -resolvePackageDependencies >/dev/null
fi
[ -x "$GEN" ] || { echo "FAILED: generate_appcast not found at $GEN"; exit 1; }

echo "==> Generating signed appcast"
"$GEN" "$DIST" -o "$DIST/appcast.xml" \
  --download-url-prefix "https://github.com/magicelk235/viaduct-app/releases/download/v$VERSION/"

echo "==> Done: $OUT (signed + notarized + stapled — ships clean on any Mac)"
echo
echo "Publish — the tag MUST be v$VERSION or the appcast's download URLs 404:"
echo "  gh release create v$VERSION \\"
echo "    \"$OUT\" \"$ZIP\" \"$DIST/appcast.xml\" \\"
echo "    --title \"Viaduct $VERSION\" --notes \"...\""
