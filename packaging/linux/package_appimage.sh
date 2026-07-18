#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
  echo "usage: $0 FLUTTER_BUNDLE APPIMAGETOOL OUTPUT.AppImage" >&2
  exit 64
fi

bundle=$1
tool=$2
output=$3
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
expected=$(sed -n '/"appimagetool"/,/}/{s/.*"sha256": "\([0-9a-f]*\)".*/\1/p;}' "$repo/tool/release/tool_manifest.json")
actual=$(sha256sum "$tool" | cut -d ' ' -f 1)
test "$actual" = "$expected" || { echo "appimagetool checksum mismatch" >&2; exit 1; }

appdir=$(mktemp -d)
trap 'rm -rf "$appdir"' EXIT
mkdir -p "$appdir/usr/bin" "$appdir/usr/lib/gapless/compliance"
cp -R "$bundle/." "$appdir/usr/bin/"
if [ -d "$appdir/usr/bin/lib/gapless" ]; then
  cp -R "$appdir/usr/bin/lib/gapless/." "$appdir/usr/lib/gapless/"
  rm -rf "$appdir/usr/bin/lib/gapless"
fi
cp "$repo/packaging/linux/AppRun" "$appdir/AppRun"
cp "$repo/packaging/linux/gapless.desktop" "$appdir/gapless.desktop"
cp "$repo/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png" "$appdir/gapless.png"
cp "$repo/third_party/THIRD_PARTY_NOTICES.md" "$appdir/usr/lib/gapless/compliance/"
cp "$repo/third_party/SOURCE_OFFER.md" "$appdir/usr/lib/gapless/compliance/"
chmod 755 "$appdir/AppRun" "$appdir/usr/bin/gapless" "$appdir/usr/lib/gapless/engine/auto-editor"
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$tool" "$appdir" "$output"
