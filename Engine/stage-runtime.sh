#!/bin/bash
set -euo pipefail
ENGINE="$(cd "$(dirname "$0")" && pwd)"
APP="${1:?app bundle destination required}"
BUNDLE="${NATIVE_PHOTO_DARKTABLE_BUNDLE:-/Applications/darktable.app}"
if [[ "$(/usr/bin/shasum -a 256 "$BUNDLE/Contents/Resources/lib/darktable/libdarktable.dylib" | /usr/bin/cut -d " " -f 1)" != "922a2d075e8c59d0e9d7f27e73e80cab1a39f3bf64a5ba470ce19b86945fa8db" ]]; then
  printf "%s\n" "Unverified darktable runtime; expected pinned 5.6.0 library." >&2
  exit 1
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/usr/bin/rsync -a "$BUNDLE/Contents/Resources/" "$APP/Contents/Resources/"
cp "$ENGINE/Build/MacOS/native-photo-helper" "$APP/Contents/MacOS/native-photo-helper"
cp "$ENGINE/COPYING" "$APP/Contents/Resources/darktable-COPYING"
cp "$ENGINE/source-manifest.json" "$APP/Contents/Resources/darktable-source-manifest.json"
/usr/bin/codesign --force --sign - "$APP/Contents/MacOS/native-photo-helper"
