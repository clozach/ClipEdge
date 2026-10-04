#!/bin/bash
# One command for a clean standalone checkout; no Homebrew/just/Node required.
set -euo pipefail
main() {
# Parse the full transaction before git pull can replace this script on disk.
cd -P "$(dirname "$0")/.."
if [[ $(uname -s) != Darwin ]] || ! xcrun --find swiftc >/dev/null 2>&1; then
    echo 'macOS Command Line Tools are required. Run xcode-select --install, finish the Apple installer, then retry.' >&2
    exit 1
fi
# A vault subdirectory is not a standalone checkout. Avoid pulling unrelated work.
if [[ $(git rev-parse --show-toplevel) != "$PWD" ]]; then
    echo 'Run update.sh from the standalone ClipEdge repository. In a vault checkout use tools/build.sh then tools/install.sh.' >&2
    exit 1
fi
if [[ -n $(git status --porcelain) ]]; then
    echo 'Local changes found. Preserve/commit them before updating; nothing was quit or trashed.' >&2
    exit 1
fi
git rev-parse --abbrev-ref '@{upstream}' >/dev/null
mkdir -p .build
xcrun swiftc InstallSupport.swift tools/Installer.swift -o .build/installer -framework AppKit
receipt="$PWD/.build/update-$(date +%Y%m%d-%H%M%S)-$$.json"
rollback() {
    local result=$?
    if [[ $result != 0 && -f "$receipt" ]]; then
        echo 'Update failed; restoring the previous app.' >&2
        .build/installer restore "$receipt" || echo "Restore needs attention. Receipt: $receipt" >&2
    fi
    exit "$result"
}
trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
.build/installer prepare "$receipt"
git pull --ff-only
# Run the freshly pulled build script. Keep the transaction's installer unchanged.
tools/build.sh
.build/installer finish "$receipt" "$PWD/.build/ClipEdge.app"
# Installation is now complete; an open failure is not an install rollback.
trap - EXIT
printf 'Undo: .build/installer restore "%s"\n' "$receipt"
open "$HOME/Applications/ClipEdge.app"
echo 'Check the tab position and macOS permissions using README.md.'
}
main "$@"
