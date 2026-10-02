#!/bin/bash
set -euo pipefail
ENGINE="$(cd "$(dirname "$0")" && pwd)"
APP="${1:?app bundle destination required}"
BUNDLE="${NATIVE_PHOTO_DARKTABLE_BUNDLE:-/Applications/darktable.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/usr/bin/rsync -a "$BUNDLE/Contents/Resources/" "$APP/Contents/Resources/"
cp "$ENGINE/Build/MacOS/native-photo-helper" "$APP/Contents/MacOS/native-photo-helper"
cp "$ENGINE/COPYING" "$APP/Contents/Resources/darktable-COPYING"
cp "$ENGINE/source-manifest.json" "$APP/Contents/Resources/darktable-source-manifest.json"
/usr/bin/codesign --force --sign - "$APP/Contents/MacOS/native-photo-helper"
