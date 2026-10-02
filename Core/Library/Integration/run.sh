#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
ENGINE="${NATIVE_PHOTO_ENGINE_SOURCE:-$ROOT/Engine}"
SWIFTC="${NATIVE_PHOTO_SWIFTC:-/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc}"
SDK="${NATIVE_PHOTO_SDK:-/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk}"
mkdir -p "$ROOT/build/module-cache"
"$ENGINE/build-helper.sh"
SOURCES=()
while IFS= read -r path; do SOURCES+=("$path"); done < <(find "$ROOT/Core" "$ENGINE/Native" -name '*.swift' -type f | sort)
"$SWIFTC" -sdk "$SDK" -target arm64-apple-macosx26.0 -swift-version 6 -strict-concurrency=complete -warnings-as-errors -enable-actor-data-race-checks -parse-as-library -D LIBRARY_INTEGRATION -module-name LibraryIntegration -module-cache-path "$ROOT/build/module-cache" "${SOURCES[@]}" -o "$ROOT/build/LibraryIntegration"
"$ROOT/build/LibraryIntegration"
