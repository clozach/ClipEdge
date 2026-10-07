#!/bin/bash
# Native AppKit search editing regression; captures fixture windows only.
# Borrows the clipboard in memory and restores it unless the user copied meanwhile.
set -euo pipefail
cd "$(dirname "$0")/.."
if pgrep -f 'Applications/ClipEdge.app/Contents/MacOS/ClipEdge' >/dev/null; then
    echo 'Quit the installed ClipEdge before running this fixture.' >&2
    exit 1
fi
mkdir -p .build
sources=()
for source in *.swift; do
    [[ "$source" == main.swift ]] || sources+=("$source")
done
xcrun swiftc -swift-version 5 "${sources[@]}" tools/SearchEditingCapture.swift -o .build/search-editing-capture -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon
.build/search-editing-capture "${1:-.build/search-editing-check}" --check
