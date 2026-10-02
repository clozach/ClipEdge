#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -x .build/ClipEdge.app/Contents/MacOS/ClipEdge ]] || tools/build.sh
mkdir -p .build
xcrun swiftc tools/InstallSupport.swift tools/Installer.swift -o .build/installer -framework AppKit
stage=$(mktemp -d .build/install-source.XXXXXX)
ditto .build/ClipEdge.app "$stage/ClipEdge.app"
receipt="$PWD/.build/install-$(date +%Y%m%d-%H%M%S)-$$.json"
rollback() {
    local result=$?
    if [[ $result != 0 && -f "$receipt" ]]; then
        echo "Installation failed; restoring the previous app." >&2
        .build/installer restore "$receipt" || echo "Restore needs attention. Receipt: $receipt" >&2
    fi
    rm -rf "$stage"
    exit "$result"
}
trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
.build/installer prepare "$receipt"
.build/installer finish "$receipt" "$PWD/$stage/ClipEdge.app"
printf 'Undo (quit ClipEdge first): .build/installer restore "%s"\n' "$receipt"
