#!/bin/bash
# Builds the release that installed copies update to: universal, signed with the release
# certificate, and carrying the update feed. Free and local; NOT Developer ID notarization.
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(tr -d '[:space:]' < VERSION)
identity=${CLIPEDGE_SIGN_IDENTITY:-}
if [[ -z $identity ]]; then
    identities=()
    while IFS= read -r found; do identities+=("$found"); done < <(security find-identity -v -p codesigning | awk '/^[[:space:]]*[0-9]+\)/ {print $2}')
    if [[ ${#identities[@]} == 1 ]]; then identity=${identities[0]}; fi
fi
if [[ -z $identity || $identity == - ]]; then
    cat >&2 <<'MESSAGE'
A release must be signed with one code-signing certificate. Copies signed without one cannot
update themselves, and macOS drops their Accessibility approval after every update.
Set CLIPEDGE_SIGN_IDENTITY to the certificate every release is signed with.
MESSAGE
    exit 1
fi
feed=${CLIPEDGE_UPDATE_FEED:-https://api.github.com/repos/clozach/ClipEdge/releases/latest}
# --timestamp asks Apple's server for the signing time, so the signature outlives the certificate.
CLIPEDGE_ARCHS='arm64 x86_64' CLIPEDGE_SIGN_IDENTITY="$identity" CLIPEDGE_SIGN_FLAGS='--timestamp' \
    CLIPEDGE_UPDATE_FEED="$feed" bash tools/build.sh
mkdir -p .build/releases
name="ClipEdge-$version-macOS-universal.zip"
archive="$PWD/.build/releases/$name"
rm -f "$archive"
ditto -c -k --sequesterRsrc --keepParent .build/ClipEdge.app "$archive"
(cd .build/releases && shasum -a 256 "$name" > SHA256SUMS)
# Check the archive itself, as an installed copy will: unpack, verify, read the signer.
check=$(mktemp -d .build/release-check.XXXXXX)
trap 'rm -rf "$check"' EXIT
ditto -x -k "$archive" "$check"
codesign --verify --strict "$check/ClipEdge.app"
signer=$(codesign -d -r- "$check/ClipEdge.app" 2>&1 | sed -n 's/^designated => //p')
# Keep the release build out of the development slot, so a later install.sh cannot install a
# self-updating copy by accident.
rm -rf ".build/releases/ClipEdge-$version.app"
mv .build/ClipEdge.app ".build/releases/ClipEdge-$version.app"
if [[ -e .build/ClipEdge.previous.app ]]; then mv .build/ClipEdge.previous.app .build/ClipEdge.app; fi
printf 'Prepared %s\nVersion %s, update feed %s\nInstalled copies accept an update only when it satisfies:\n  %s\nNot notarized: a copy downloaded in a browser is blocked by Gatekeeper; tools/install-release.sh and the app'"'"'s own updater are not.\n' "$archive" "$version" "$feed" "$signer"
