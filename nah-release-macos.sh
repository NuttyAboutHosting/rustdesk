#!/bin/bash
# Local macOS release build for NahSupport: build -> sign -> dmg -> notarize
# -> staple -> verify. Mirrors the build-macos-arm64 CI job so either path
# produces the same artifact; use this when CI minutes are unavailable.
#
# Prerequisites (see BUILDING.NAH.md "macOS (arm64)"):
#   - toolchain set up (Flutter 3.24.5 patched, vcpkg deps, cocoapods, Rosetta)
#   - the Developer ID Application identity imported into the login keychain
#     (double-click the .p12 from 1Password, or:
#      security import devid-legacy.p12 -P '<p12 password>' -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign)
#
# Required env:
#   NAH_RENDEZVOUS_SERVER / NAH_RS_PUB_KEY / NAH_API_BASE   client pinning
#   APPLE_API_KEY_P8   path to the App Store Connect API key .p8
#   APPLE_API_KEY_ID   its Key ID
#   APPLE_API_ISSUER_ID  the issuer id
# Optional env:
#   NAH_FLAVOR         support (default) | technician
#   SKIP_BUILD=1       sign/notarize the existing build only
set -euo pipefail

cd "$(dirname "$0")"
FLAVOR="${NAH_FLAVOR:-support}"
APP="flutter/build/macos/Build/Products/Release/NAHSupport.app"
ENTITLEMENTS="flutter/macos/Runner/Release.entitlements"
if [ "$FLAVOR" = "support" ]; then OUT_DMG="NahSupport.dmg"; else OUT_DMG="NahSupportTechnician.dmg"; fi

for v in NAH_RENDEZVOUS_SERVER NAH_RS_PUB_KEY NAH_API_BASE APPLE_API_KEY_P8 APPLE_API_KEY_ID APPLE_API_ISSUER_ID; do
  [ -n "${!v:-}" ] || { echo "error: $v is not set" >&2; exit 1; }
done
[ -f "$APPLE_API_KEY_P8" ] || { echo "error: APPLE_API_KEY_P8 file not found: $APPLE_API_KEY_P8" >&2; exit 1; }

# Default toolchain env if not already set (matches BUILDING.NAH.md).
export LIBCLANG_PATH="${LIBCLANG_PATH:-/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib}"
export VCPKG_ROOT="${VCPKG_ROOT:-$HOME/vcpkg}"
export LANG="${LANG:-en_US.UTF-8}"
command -v flutter >/dev/null || export PATH="$HOME/flutter-3245/flutter/bin:$PATH"

IDENTITY="$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.+)"$/\1/')"
[ -n "$IDENTITY" ] || { echo "error: no 'Developer ID Application' identity in the keychain - import the .p12 first" >&2; exit 1; }
echo "==> Signing as: $IDENTITY"

if [ -z "${SKIP_BUILD:-}" ]; then
  echo "==> Building ($FLAVOR)"
  NAH_FLAVOR="$FLAVOR" python3 ./build.py --flutter --hwcodec --unix-file-copy-paste --screencapturekit
fi
[ -d "$APP" ] || { echo "error: $APP not found" >&2; exit 1; }

echo "==> Codesigning (inside-out, hardened runtime)"
# Nested non-executable Mach-O first (dylibs, frameworks), no entitlements.
find "$APP/Contents" -type f \( -name "*.dylib" -o -perm +111 \) -not -path "*/Contents/MacOS/*" -print0 |
  while IFS= read -r -d '' f; do
    if file "$f" | grep -q "Mach-O"; then
      codesign --force --options runtime --timestamp --sign "$IDENTITY" "$f"
    fi
  done
find "$APP/Contents/Frameworks" -maxdepth 1 -name "*.framework" -print0 |
  while IFS= read -r -d '' fw; do
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$fw"
  done
# Executables (app binary + service helper) with entitlements, then the bundle.
find "$APP/Contents/MacOS" -type f -print0 |
  while IFS= read -r -d '' f; do
    if file "$f" | grep -q "Mach-O"; then
      codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$f"
    fi
  done
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Creating $OUT_DMG"
rm -f "$OUT_DMG"
create-dmg --volname "NAHSupport" \
  --window-pos 200 120 --window-size 800 400 --icon-size 100 \
  --icon "NAHSupport.app" 200 190 --hide-extension "NAHSupport.app" \
  --app-drop-link 600 185 \
  "$OUT_DMG" "$APP"
codesign --force --timestamp --sign "$IDENTITY" "$OUT_DMG"

echo "==> Notarizing (this waits on Apple, typically 1-10 min)"
xcrun notarytool submit "$OUT_DMG" \
  --key "$APPLE_API_KEY_P8" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" \
  --wait
xcrun stapler staple "$OUT_DMG"

echo "==> Gatekeeper verification"
spctl -a -vvv -t install "$OUT_DMG"
codesign -dv --verbose=2 "$OUT_DMG" 2>&1 | grep -E "Authority|TeamIdentifier|Timestamp"
echo "==> Done: $OUT_DMG"
