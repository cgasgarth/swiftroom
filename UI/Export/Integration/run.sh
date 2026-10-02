#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
ENGINE="${NATIVE_PHOTO_ENGINE_SOURCE:-$ROOT/Engine}"
CORE="${NATIVE_PHOTO_CORE_SOURCE:-$ROOT/Core}"
LIBRARY="${NATIVE_PHOTO_LIBRARY_SOURCE:-$CORE/Library}"
SWIFTC="${NATIVE_PHOTO_SWIFTC:-/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc}"
SDK="${NATIVE_PHOTO_SDK:-/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk}"
mkdir -p "$ROOT/build/module-cache" "$ROOT/build/ExportIntegration"
SOURCES=()
while IFS= read -r path; do SOURCES+=("$path"); done < <(find "$CORE" "$ENGINE/Native" "$ROOT/UI/Export" -name '*.swift' -type f | sort)
if test "$LIBRARY" != "$CORE/Library"; then
    while IFS= read -r path; do SOURCES+=("$path"); done < <(find "$LIBRARY" -name '*.swift' -type f | sort)
fi
"$SWIFTC" -sdk "$SDK" -target arm64-apple-macosx26.0 -swift-version 6 -strict-concurrency=complete -warnings-as-errors -enable-actor-data-race-checks -parse-as-library -D EXPORT_INTEGRATION -module-name ExportIntegration -module-cache-path "$ROOT/build/module-cache" "${SOURCES[@]}" -o "$ROOT/build/ExportIntegration/ExportWorkflow"
NATIVE_PHOTO_HELPER="${NATIVE_PHOTO_HELPER:-$ENGINE/Build/MacOS/native-photo-helper}" "$ROOT/build/ExportIntegration/ExportWorkflow" "$ROOT/build/ExportIntegration"
