#!/bin/bash
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/../../.." && pwd)"
MASKS_ROOT="$PROJECT/UI/Masks"
CORE_ROOT="${NATIVE_PHOTO_CORE_SOURCE:-$PROJECT/Core}"
ENGINE_ROOT="${NATIVE_PHOTO_ENGINE_SOURCE:-$PROJECT/Engine}"
CONTRACT_ROOT="${NATIVE_PHOTO_MASK_CONTRACT_SOURCE:-$CORE_ROOT/Masks}"
LIBRARY_ROOT="${NATIVE_PHOTO_LIBRARY_SOURCE:-$CORE_ROOT/Library}"
SWIFTC="${NATIVE_PHOTO_SWIFTC:-/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc}"
SDK="${NATIVE_PHOTO_SDK:-/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk}"
mkdir -p "$PROJECT/build/module-cache"
SOURCES=()
while IFS= read -r path; do SOURCES+=("$path"); done < <(find "$MASKS_ROOT/Integration" -name '*.swift' -type f | sort)
while IFS= read -r path; do SOURCES+=("$path"); done < <(find "$MASKS_ROOT" -maxdepth 1 -name '*.swift' -type f | sort)
while IFS= read -r path; do SOURCES+=("$path"); done < <(find "$CORE_ROOT" "$ENGINE_ROOT/Native" -name '*.swift' -type f ! -path "$CORE_ROOT/Masks/*" | sort)
while IFS= read -r path; do SOURCES+=("$path"); done < <(find "$CONTRACT_ROOT" -name '*.swift' -type f | sort)
if test "$LIBRARY_ROOT" != "$CORE_ROOT/Library"; then
    while IFS= read -r path; do SOURCES+=("$path"); done < <(find "$LIBRARY_ROOT" -name '*.swift' -type f | sort)
fi
"$SWIFTC" -sdk "$SDK" -target arm64-apple-macosx26.0 -swift-version 6 -strict-concurrency=complete -warnings-as-errors -enable-actor-data-race-checks -parse-as-library -D MASK_INSPECTOR_INTEGRATION -module-name MaskInspectorWorkflow -module-cache-path "$PROJECT/build/module-cache" "${SOURCES[@]}" -o "$PROJECT/build/MaskInspectorWorkflow"
"$PROJECT/build/MaskInspectorWorkflow" "$@"
