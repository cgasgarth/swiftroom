#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFTC="${NATIVE_PHOTO_SWIFTC:-/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc}"
SDK="${NATIVE_PHOTO_SDK:-/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk}"
mkdir -p "$ROOT/build/module-cache"
ENGINE_ROOT="${NATIVE_PHOTO_ENGINE_SOURCE:-$ROOT/Engine}"
LIBRARY_ROOT="${NATIVE_PHOTO_LIBRARY_SOURCE:-$ROOT/Core/Library}"
"$ENGINE_ROOT/build-helper.sh"
SOURCES=()
while IFS= read -r path; do SOURCES+=("$path"); done < <(find "$ROOT/Core" "$ROOT/Tests" "$ENGINE_ROOT/Native" -name '*.swift' -type f -not -path '*/Integration/*' | sort)
if test "$LIBRARY_ROOT" != "$ROOT/Core/Library"; then
    while IFS= read -r path; do SOURCES+=("$path"); done < <(find "$LIBRARY_ROOT" -name '*.swift' -type f -not -path '*/Integration/*' | sort)
fi
"$SWIFTC" -sdk "$SDK" -target arm64-apple-macosx26.0 -swift-version 6 -strict-concurrency=complete -warnings-as-errors -enable-actor-data-race-checks -parse-as-library -module-name NativePhotoTests -module-cache-path "$ROOT/build/module-cache" "${SOURCES[@]}" -o "$ROOT/build/NativePhotoTests"
NATIVE_PHOTO_HELPER="$ENGINE_ROOT/Build/MacOS/native-photo-helper" NATIVE_PHOTO_TEST_OUTPUT="$ROOT/build/Integration" "$ROOT/build/NativePhotoTests" "$@"
