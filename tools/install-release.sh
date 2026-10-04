#!/bin/bash
# Installs the latest published release without building it. That release is signed with one
# certificate and keeps itself up to date, so macOS permissions are approved once.
# Exit 3: the latest release is not such a copy; build from source instead (tools/update.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $(uname -s) != Darwin ]] || ! xcrun --find swiftc >/dev/null 2>&1; then
    echo 'macOS Command Line Tools are required. Run xcode-select --install, finish the Apple installer, then retry.' >&2
    exit 1
fi
api=${CLIPEDGE_RELEASE_API:-https://api.github.com/repos/clozach/ClipEdge/releases/latest}
mkdir -p .build
work=$(mktemp -d .build/release-install.XXXXXX)
receipt="$PWD/.build/install-$(date +%Y%m%d-%H%M%S)-$$.json"
finish() {
    local result=$?
    if [[ $result != 0 && -f "$receipt" ]]; then
        echo 'Installation failed; restoring the previous app.' >&2
        .build/installer restore "$receipt" || echo "Restore needs attention. Receipt: $receipt" >&2
    fi
    rm -rf "$work"
    exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
curl -fsSL -H 'Accept: application/vnd.github+json' "$api" -o "$work/latest.json"
tag=$(plutil -extract tag_name raw -o - "$work/latest.json")
count=$(plutil -extract assets raw -o - "$work/latest.json")
zip_url='' sums_url='' zip_name=''
for ((index = 0; index < count; index++)); do
    asset=$(plutil -extract "assets.$index.name" raw -o - "$work/latest.json")
    url=$(plutil -extract "assets.$index.browser_download_url" raw -o - "$work/latest.json")
    case "$asset" in
        ClipEdge*.zip) zip_url=$url; zip_name=$asset ;;
        SHA256SUMS) sums_url=$url ;;
    esac
done
[[ -n $zip_url && -n $sums_url ]] || { echo "Release $tag has no ClipEdge download with a checksum." >&2; exit 1; }
curl -fsSL "$zip_url" -o "$work/$zip_name"
curl -fsSL "$sums_url" -o "$work/SHA256SUMS"
(cd "$work" && shasum -a 256 -c SHA256SUMS >/dev/null)
ditto -x -k "$work/$zip_name" "$work/unpacked"
app="$work/unpacked/ClipEdge.app"
codesign --verify --strict "$app"
if codesign -dv "$app" 2>&1 | grep -q '^Signature=adhoc' || ! /usr/libexec/PlistBuddy -c 'Print :ClipEdgeUpdateFeed' "$app/Contents/Info.plist" >/dev/null 2>&1; then
    echo "Release $tag is not a self-updating copy (no certificate signature or no update feed). Nothing was changed. Build from source with: bash tools/update.sh" >&2
    exit 3
fi
xcrun swiftc InstallSupport.swift tools/Installer.swift -o .build/installer -framework AppKit
.build/installer prepare "$receipt"
.build/installer finish "$receipt" "$PWD/$app"
trap - EXIT
rm -rf "$work"
printf 'Installed ClipEdge %s (%s). Undo (quit ClipEdge first): .build/installer restore "%s"\n' "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$HOME/Applications/ClipEdge.app/Contents/Info.plist")" "$tag" "$receipt"
open "$HOME/Applications/ClipEdge.app"
cat <<'NEXT'
Two things remain, once:
1. System Settings → Privacy & Security: approve ClipEdge under Accessibility and Input Monitoring.
   If an older ClipEdge is listed there, remove it (−), then add or approve this one. Quit and reopen ClipEdge.
2. Answer "Keep ClipEdge up to date automatically?". After that it updates itself and keeps these approvals.
NEXT
