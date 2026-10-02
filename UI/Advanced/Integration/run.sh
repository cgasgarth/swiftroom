#!/bin/bash
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/../../.." && pwd)"
ADVANCED_ROOT="$PROJECT/UI/Advanced"
CORE_ROOT="${NATIVE_PHOTO_CORE_SOURCE:-$PROJECT/Core}"
ENGINE_ROOT="${NATIVE_PHOTO_ENGINE_SOURCE:-$PROJECT/Engine}"
LIBRARY_ROOT="${NATIVE_PHOTO_LIBRARY_SOURCE:-$CORE_ROOT/Library}"
WORKFLOW_BINARY="${NATIVE_PHOTO_ADVANCED_EXECUTABLE:-$PROJECT/build/AdvancedModuleWorkflow}"
SWIFTC="${NATIVE_PHOTO_SWIFTC:-/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc}"
SDK="${NATIVE_PHOTO_SDK:-/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk}"
mkdir -p "$PROJECT/build/module-cache"
SOURCES=("$ADVANCED_ROOT/AdvancedModuleEditor.swift" "$ADVANCED_ROOT/AdvancedParameterValue.swift" "$ADVANCED_ROOT/AdvancedFieldPresentation.swift" "$ADVANCED_ROOT/Integration/AdvancedModuleWorkflow.swift")
while IFS= read -r path; do SOURCES+=("$path"); done < <(find "$CORE_ROOT" "$ENGINE_ROOT/Native" -name '*.swift' -type f | sort)
if test "$LIBRARY_ROOT" != "$CORE_ROOT/Library"; then
    while IFS= read -r path; do SOURCES+=("$path"); done < <(find "$LIBRARY_ROOT" -name '*.swift' -type f | sort)
fi
"$SWIFTC" -sdk "$SDK" -target arm64-apple-macosx26.0 -swift-version 6 -strict-concurrency=complete -warnings-as-errors -enable-actor-data-race-checks -parse-as-library -D ADVANCED_MODULE_INTEGRATION -module-name AdvancedModuleWorkflow -module-cache-path "$PROJECT/build/module-cache" "${SOURCES[@]}" -o "$WORKFLOW_BINARY"
"$WORKFLOW_BINARY" "$@"
