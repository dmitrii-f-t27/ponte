#!/usr/bin/env bash
# Builds dist/Ponte.app (release) and signs it.
# Signing uses the first "Apple Development" identity in the keychain, so TCC grants
# (microphone, audio capture, speech) survive rebuilds; ad-hoc ("-") otherwise.
#   PONTE_SCRATCH=<dir>   SwiftPM scratch path (default: .build)
#   PONTE_SIGN=<identity> force a signing identity (hash or name)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="${PONTE_SCRATCH:-$ROOT/.build}"
APP="$ROOT/dist/Ponte.app"

echo "==> swift build -c release"
swift build -c release --package-path "$ROOT" --scratch-path "$SCRATCH" --product Ponte
BIN_DIR="$(swift build -c release --package-path "$ROOT" --scratch-path "$SCRATCH" --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Ponte" "$APP/Contents/MacOS/Ponte"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
# The Ponte Camera extension (camera/extension, with cm.wasm built from the camera spec by camera/build-wasm.sh):
# Ponte copies it to ~/Library/Application Support/Ponte/PonteCamera, which BrowserOS loads unpacked.
rm -rf "$APP/Contents/Resources/PonteCamera"
cp -R "$ROOT/camera/extension" "$APP/Contents/Resources/PonteCamera"
# SwiftPM resource bundles, if any target ever declares resources.
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle "$BIN_DIR"/*.resources; do
    cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob
plutil -lint "$APP/Contents/Info.plist" >/dev/null

IDENTITY="${PONTE_SIGN:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk '/"Apple Development/ { print $2; exit }')"
fi
ENTITLEMENTS="$ROOT/Resources/Ponte.entitlements"
if [[ -n "$IDENTITY" ]]; then
    echo "==> codesign with Apple Development identity $IDENTITY"
    codesign --force --options runtime --timestamp=none \
        --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
else
    echo "==> no Apple Development identity: ad-hoc signature (TCC may ask again after each rebuild)"
    codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign - "$APP"
fi
codesign --verify --strict "$APP"

echo "$APP"
