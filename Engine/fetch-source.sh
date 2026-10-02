#!/bin/bash
set -euo pipefail
ENGINE="$(cd "$(dirname "$0")" && pwd)"
REVISION=3c17b2976793303c186a5f64e8c9635ecf8b15d3
SOURCE="$ENGINE/Upstream/darktable-5.6.0"
if test -f "$SOURCE/src/common/darktable.h"; then exit 0; fi
mkdir -p "$SOURCE"
curl --fail --location --silent --show-error "https://api.github.com/repos/darktable-org/darktable/tarball/$REVISION" -o "$ENGINE/Upstream/darktable-5.6.0.tar.gz"
tar -xzf "$ENGINE/Upstream/darktable-5.6.0.tar.gz" --strip-components=1 -C "$SOURCE"
