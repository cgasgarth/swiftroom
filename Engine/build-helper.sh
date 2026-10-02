#!/bin/bash
set -euo pipefail
ENGINE="$(cd "$(dirname "$0")" && pwd)"
"$ENGINE/fetch-source.sh"
SOURCE="$ENGINE/Upstream/darktable-5.6.0/src"
BUNDLE="${NATIVE_PHOTO_DARKTABLE_BUNDLE:-/Applications/darktable.app}/Contents/Resources"
BUILD="$ENGINE/Build"
mkdir -p "$BUILD/MacOS" "$BUILD/Resources/lib" "$BUILD/include"
ln -sfn /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/OpenCL.framework/Headers "$BUILD/include/CL"
for library in "$BUNDLE"/lib/*.dylib; do ln -sfn "$library" "$BUILD/Resources/lib/$(basename "$library")"; done
ln -sfn "$BUNDLE/lib/darktable" "$BUILD/Resources/lib/darktable"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
FLAGS=$(/opt/homebrew/bin/pkg-config --cflags json-glib-1.0 gtk+-3.0 lcms2 librsvg-2.0)
/usr/bin/clang -O2 -g -std=c11 -Wall -Wextra -Werror -DHAVE_OPENCL -I"$BUILD/include" -D_DARWIN_C_SOURCE -D_RELEASE -DGETTEXT_PACKAGE=\"darktable\" -isystem "$SOURCE" -I"$ENGINE/Helper" $FLAGS "$ENGINE/Helper/main.c" "$ENGINE/Helper/module_bridge.c" "$ENGINE/Helper/pipeline.c" "$ENGINE/Helper/white_balance.c" -L"$BUNDLE/lib/darktable" -ldarktable "$BUNDLE/lib/libglib-2.0.0.dylib" "$BUNDLE/lib/libgobject-2.0.0.dylib" "$BUNDLE/lib/libjson-glib-1.0.0.dylib" -Wl,-rpath,@executable_path/../Resources/lib/darktable "$BUNDLE/lib/liblcms2.2.dylib" -o "$BUILD/MacOS/native-photo-helper"
printf '%s\n' "$BUILD/MacOS/native-photo-helper"
