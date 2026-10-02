#!/bin/bash
# Free, locally built universal binary. This is NOT Developer ID notarization.
set -euo pipefail
cd "$(dirname "$0")/.."
CLIPEDGE_ARCHS='arm64 x86_64' CLIPEDGE_SIGN_IDENTITY=- bash tools/build.sh
mkdir -p .build/releases
archive="$PWD/.build/releases/ClipEdge-2.0-macOS-universal.zip"
ditto -c -k --sequesterRsrc --keepParent .build/ClipEdge.app "$archive"
(cd .build/releases && shasum -a 256 ClipEdge-2.0-macOS-universal.zip > SHA256SUMS)
printf 'Prepared %s\nAd-hoc signed; not notarized. macOS may block first launch. README documents the source-build alternative.\n' "$archive"
