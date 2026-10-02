#!/bin/bash
set -euo pipefail
ENGINE="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT="$(dirname "$ENGINE")"
OUTPUT="${3:-$ENGINE/Artifacts/bezier-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
cp "$1" "$OUTPUT/source.${1##*.}"
"$ENGINE/build-helper.sh"
SWIFTC=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
SOURCES=("$PROJECT/Core/EngineContract.swift" "$PROJECT/Core/ModuleContract.swift" "$PROJECT/Core/ExportProtection.swift")
while IFS= read -r path; do SOURCES+=("$path"); done < <(find "$PROJECT/Core/Masks" "$ENGINE/Native" "$ENGINE/Integration/Bezier" -name '*.swift' -type f | sort)
"$SWIFTC" -sdk "$SDK" -target arm64-apple-macosx26.0 -swift-version 6 -strict-concurrency=complete -warnings-as-errors -enable-actor-data-race-checks -parse-as-library -module-cache-path "$ENGINE/Build/swift-module-cache" -O "${SOURCES[@]}" -o "$ENGINE/Build/MacOS/bezier-integration"
NATIVE_PHOTO_HELPER="$ENGINE/Build/MacOS/native-photo-helper" "$ENGINE/Build/MacOS/bezier-integration" "$OUTPUT/source.${1##*.}" "$2" "$OUTPUT"
