#!/bin/bash
set -euo pipefail
ENGINE="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ENGINE/Upstream/darktable-5.6.0/src"
BUNDLE="${NATIVE_PHOTO_DARKTABLE_BUNDLE:-/Applications/darktable.app}/Contents/Resources"
BUILD="$ENGINE/Build"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
FLAGS=$(/opt/homebrew/bin/pkg-config --cflags json-glib-1.0 gtk+-3.0 lcms2 librsvg-2.0)
/usr/bin/clang -O2 -g -std=c11 -Wall -Wextra -Werror -DHAVE_OPENCL -I"$BUILD/include" -D_DARWIN_C_SOURCE -D_RELEASE -DGETTEXT_PACKAGE=\"darktable\" -isystem "$SOURCE" -I"$ENGINE/Helper" $FLAGS "$ENGINE/Integration/FixtureGenerator.c" "$ENGINE/Helper/module_bridge.c" -L"$BUNDLE/lib/darktable" -ldarktable "$BUNDLE/lib/libglib-2.0.0.dylib" "$BUNDLE/lib/libgobject-2.0.0.dylib" "$BUNDLE/lib/libjson-glib-1.0.0.dylib" -Wl,-rpath,@executable_path/../Resources/lib/darktable -o "$BUILD/MacOS/fixture-generator"
"$BUILD/MacOS/fixture-generator" "$@"
