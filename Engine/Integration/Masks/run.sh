#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT="$(dirname "$ROOT")"
SOURCE="$ROOT/Upstream/darktable-5.6.0/src"
BUNDLE=/Applications/darktable.app/Contents/Resources
OUTPUT="${3:-$ROOT/Artifacts/masks-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUTPUT/config" "$OUTPUT/cache"
OUTPUT="$(cd "$OUTPUT" && pwd)"
XMP="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
cp "$1" "$OUTPUT/source.${1##*.}"
RAW="$OUTPUT/source.${1##*.}"
"$ROOT/build-helper.sh"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
FLAGS=$(/opt/homebrew/bin/pkg-config --cflags json-glib-1.0 gtk+-3.0 lcms2 librsvg-2.0)
/usr/bin/clang -O2 -std=c11 -Wall -Wextra -Werror -DHAVE_OPENCL -I"$ROOT/Build/include" -D_DARWIN_C_SOURCE -D_RELEASE -DGETTEXT_PACKAGE=\"darktable\" -isystem "$SOURCE" -I"$ROOT/Helper" $FLAGS "$ROOT/Integration/Masks/Fixture.c" -L"$BUNDLE/lib/darktable" -ldarktable "$BUNDLE/lib/libglib-2.0.0.dylib" "$BUNDLE/lib/libgobject-2.0.0.dylib" -Wl,-rpath,@executable_path/../Resources/lib/darktable -o "$ROOT/Build/MacOS/mask-fixture"
"$ROOT/Build/MacOS/mask-fixture" "$RAW" "$XMP" "$OUTPUT/fixture.xmp" native-photo --configdir "$OUTPUT/config" --cachedir "$OUTPUT/cache" --library "$OUTPUT/library.db" --datadir "$BUNDLE/share/darktable" --moduledir "$BUNDLE/lib/darktable" --conf write_sidecar_files=never --conf opencl=FALSE >"$OUTPUT/fixture.log" 2>&1
SWIFTC=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
SOURCES=("$PROJECT/Core/EngineContract.swift" "$PROJECT/Core/ModuleContract.swift" "$PROJECT/Core/ExportProtection.swift")
while IFS= read -r path; do SOURCES+=("$path"); done < <(find "$PROJECT/Core/Masks" "$ROOT/Native" "$ROOT/Integration/Masks" -name '*.swift' -type f | sort)
"$SWIFTC" -sdk "$SDK" -target arm64-apple-macosx26.0 -swift-version 6 -strict-concurrency=complete -warnings-as-errors -enable-actor-data-race-checks -parse-as-library -module-cache-path "$ROOT/Build/swift-module-cache" -O "${SOURCES[@]}" -o "$ROOT/Build/MacOS/mask-integration"
NATIVE_PHOTO_HELPER="$ROOT/Build/MacOS/native-photo-helper" "$ROOT/Build/MacOS/mask-integration" "$RAW" "$OUTPUT/fixture.xmp" "$OUTPUT"
