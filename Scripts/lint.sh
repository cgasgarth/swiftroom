#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export TOOLCHAIN_DIR="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain"
PATHS=("$ROOT/App" "$ROOT/Core" "$ROOT/Tests")
for directory in "${NATIVE_PHOTO_ENGINE_SOURCE:-$ROOT/Engine}" "${NATIVE_PHOTO_UI_SOURCE:-$ROOT/UI}"; do
    if test -d "$directory"; then PATHS+=("$directory"); fi
done
swiftlint lint --strict --no-cache --config "$ROOT/.swiftlint.yml" "${PATHS[@]}"
