#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: $0 Gapless.app OUTPUT.dmg" >&2
  exit 64
fi

app=$(CDPATH='' cd -- "$(dirname -- "$1")" && pwd)/$(basename -- "$1")
output=$(CDPATH='' cd -- "$(dirname -- "$2")" && pwd)/$(basename -- "$2")
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
identity=${GAPLESS_MACOS_SIGN_IDENTITY:?GAPLESS_MACOS_SIGN_IDENTITY is required}
mkdir -p "$app/Contents/Resources/compliance"
cp "$repo/third_party/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/compliance/"
cp "$repo/third_party/SOURCE_OFFER.md" "$app/Contents/Resources/compliance/"
codesign --force --options runtime --timestamp --sign "$identity" "$app/Contents/Resources/engine/auto-editor"
case "$(uname -m)" in
  arm64) engine_target=macos-arm64 ;;
  x86_64) engine_target=macos-x64 ;;
  *) echo "unsupported macOS architecture" >&2; exit 1 ;;
esac
(cd "$repo" && dart run tool/release/stamp_installed_engine.dart --bundle "$app" --target "$engine_target")
codesign --force --options runtime --timestamp --sign "$identity" "$app/Contents/Resources/gapless_process_host"
find "$app/Contents/Frameworks" -type f -name '*.dylib' \
  -exec codesign --force --timestamp --sign "$identity" {} \;
find "$app/Contents/Frameworks" -depth -type d -name '*.framework' \
  -exec codesign --force --timestamp --sign "$identity" {} \;
codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
(cd "$repo" && dart run tool/release/verify_bundle.dart --bundle "$app" --target "$engine_target")
hdiutil create -volname Gapless -srcfolder "$app" -ov -format UDZO "$output"
codesign --force --timestamp --sign "$identity" "$output"

if [ -n "${GAPLESS_NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$output" --keychain-profile "$GAPLESS_NOTARY_PROFILE" --wait
  xcrun stapler staple "$output"
fi
