#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."

WILDLIFE_CONFIGURATION="${WILDLIFE_CONFIGURATION:-release}"
WILDLIFE_CODESIGN_IDENTITY="${WILDLIFE_CODESIGN_IDENTITY:--}"
WILDLIFE_APP_DIR=".build/Wildlife.app"

if [[ "${WILDLIFE_UNIVERSAL:-0}" == "1" ]]; then
  swift build -c "$WILDLIFE_CONFIGURATION" --arch arm64 --arch x86_64
  WILDLIFE_BIN_DIR="$(swift build -c "$WILDLIFE_CONFIGURATION" --arch arm64 --arch x86_64 --show-bin-path)"
else
  swift build -c "$WILDLIFE_CONFIGURATION"
  WILDLIFE_BIN_DIR="$(swift build -c "$WILDLIFE_CONFIGURATION" --show-bin-path)"
fi

rm -rf "$WILDLIFE_APP_DIR"
mkdir -p "$WILDLIFE_APP_DIR/Contents/MacOS" "$WILDLIFE_APP_DIR/Contents/Resources"
cp Resources/Info.plist "$WILDLIFE_APP_DIR/Contents/Info.plist"
cp "$WILDLIFE_BIN_DIR/Wildlife" "$WILDLIFE_APP_DIR/Contents/MacOS/Wildlife"
cp "$WILDLIFE_BIN_DIR/wildlife-hook" "$WILDLIFE_APP_DIR/Contents/Resources/wildlife-hook"
chmod 755 "$WILDLIFE_APP_DIR/Contents/MacOS/Wildlife" "$WILDLIFE_APP_DIR/Contents/Resources/wildlife-hook"

codesign --force --deep --options runtime --timestamp \
  --entitlements Resources/Wildlife.entitlements \
  --sign "$WILDLIFE_CODESIGN_IDENTITY" \
  "$WILDLIFE_APP_DIR"

codesign --verify --deep --strict --verbose=2 "$WILDLIFE_APP_DIR"

if [[ -n "${WILDLIFE_NOTARY_PROFILE:-}" && "$WILDLIFE_CODESIGN_IDENTITY" != "-" ]]; then
  WILDLIFE_ARCHIVE=".build/Wildlife-notarization.zip"
  ditto -c -k --keepParent "$WILDLIFE_APP_DIR" "$WILDLIFE_ARCHIVE"
  xcrun notarytool submit "$WILDLIFE_ARCHIVE" --keychain-profile "$WILDLIFE_NOTARY_PROFILE" --wait
  xcrun stapler staple "$WILDLIFE_APP_DIR"
fi

echo "Packaged $WILDLIFE_APP_DIR"
