#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFTC="${NATIVE_PHOTO_SWIFTC:-/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc}"
SDK="${NATIVE_PHOTO_SDK:-/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk}"
APP="$ROOT/build/swiftroom.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/build/module-cache"
SOURCES=()
while IFS= read -r path; do SOURCES+=("$path"); done < <(find "$ROOT/App" "$ROOT/Core" "$ROOT/Engine" "$ROOT/UI" -name '*.swift' -type f | sort)
"$SWIFTC" -sdk "$SDK" -target arm64-apple-macosx26.0 -swift-version 6 -strict-concurrency=complete -warnings-as-errors -enable-actor-data-race-checks -parse-as-library -module-name NativePhoto -module-cache-path "$ROOT/build/module-cache" -g -O "${SOURCES[@]}" -o "$APP/Contents/MacOS/swiftroom"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"
if test -d "$ROOT/App/Resources"; then cp -R "$ROOT/App/Resources/." "$APP/Contents/Resources/"; fi
/usr/bin/codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
