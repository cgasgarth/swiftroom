#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFTC="${NATIVE_PHOTO_SWIFTC:-/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc}"
SDK="${NATIVE_PHOTO_SDK:-/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk}"
APP="$ROOT/build/swiftroom.app"
ENGINE_ROOT="${NATIVE_PHOTO_ENGINE_SOURCE:-$ROOT/Engine}"
UI_ROOT="${NATIVE_PHOTO_UI_SOURCE:-$ROOT/UI}"
LIBRARY_ROOT="${NATIVE_PHOTO_LIBRARY_SOURCE:-$ROOT/Core/Library}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/build/module-cache"
"$ENGINE_ROOT/build-helper.sh"
"$ENGINE_ROOT/stage-runtime.sh" "$APP"
SOURCES=()
while IFS= read -r path; do SOURCES+=("$path"); done < <(find "$ROOT/App" "$ROOT/Core" "$ENGINE_ROOT/Native" "$UI_ROOT" -name '*.swift' -type f | sort)
if test "$LIBRARY_ROOT" != "$ROOT/Core/Library"; then
    while IFS= read -r path; do SOURCES+=("$path"); done < <(find "$LIBRARY_ROOT" -name '*.swift' -type f | sort)
fi
for extra in "${NATIVE_PHOTO_ADVANCED_SOURCE:-}" "${NATIVE_PHOTO_EXPORT_SOURCE:-}" "${NATIVE_PHOTO_LIBRARY_UI_SOURCE:-}"; do
    if test -n "$extra"; then
        while IFS= read -r path; do SOURCES+=("$path"); done < <(find "$extra" -name '*.swift' -type f | sort)
    fi
done
"$SWIFTC" -sdk "$SDK" -target arm64-apple-macosx26.0 -swift-version 6 -strict-concurrency=complete -warnings-as-errors -enable-actor-data-race-checks -parse-as-library -module-name NativePhoto -module-cache-path "$ROOT/build/module-cache" -g -O "${SOURCES[@]}" -o "$APP/Contents/MacOS/swiftroom"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"
if test -d "$ROOT/App/Resources"; then cp -R "$ROOT/App/Resources/." "$APP/Contents/Resources/"; fi
/usr/bin/codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
