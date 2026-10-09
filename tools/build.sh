#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $(uname -s) != Darwin ]] || ! xcrun --find swiftc >/dev/null 2>&1; then
    echo 'Install Apple Command Line Tools with xcode-select --install, then retry.' >&2
    exit 1
fi
version=$(tr -d '[:space:]' < VERSION)
[[ $version =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || { echo "VERSION must look like 2.1 or 2.1.0; found '$version'." >&2; exit 1; }
mkdir -p .build
xcrun swiftc tools/publisher/Identity.swift tools/publisher/IdentityMain.swift -o .build/content-identity
content_fingerprint=$(.build/content-identity "$PWD")
bundle_stage=$(mktemp -d .build/bundle.XXXXXX)
trap 'rm -rf "$bundle_stage"' EXIT
mkdir -p "$bundle_stage/ClipEdge.app/Contents/MacOS"
archs=( ${CLIPEDGE_ARCHS:-$(uname -m)} )
binaries=()
for arch in "${archs[@]}"; do
    case "$arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac
    binary="$bundle_stage/ClipEdge-$arch"
    xcrun swiftc -swift-version 5 -target "$arch-apple-macos14.0" -O *.swift -o "$binary" -framework AppKit -framework QuickLookUI -framework Vision -framework Carbon -framework QuickLookThumbnailing -framework AVFoundation
    binaries+=("$binary")
done
lipo -create "${binaries[@]}" -output "$bundle_stage/ClipEdge.app/Contents/MacOS/ClipEdge"
cat > "$bundle_stage/ClipEdge.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.codex.ClipEdge</string>
<key>CFBundleName</key><string>ClipEdge</string>
<key>CFBundleExecutable</key><string>ClipEdge</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>ClipEdgeContentFingerprint</key><string>$content_fingerprint</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [[ -f Resources/AppIcon.icns ]]; then
    for icon_bundle in "ClipEdge.app"; do
        mkdir -p "$bundle_stage/$icon_bundle/Contents/Resources"
        cp Resources/AppIcon.icns "$bundle_stage/$icon_bundle/Contents/Resources/AppIcon.icns"
        /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon.icns' "$bundle_stage/$icon_bundle/Contents/Info.plist"
    done
fi
# Only a published release names an update feed. A source build never replaces
# itself; the canonical maintainer build separately checks publication status.
if [[ -n ${CLIPEDGE_UPDATE_FEED:-} ]]; then
    /usr/libexec/PlistBuddy -c "Add :ClipEdgeUpdateFeed string $CLIPEDGE_UPDATE_FEED" "$bundle_stage/ClipEdge.app/Contents/Info.plist"
fi
# Maintainer capabilities are absent from public exports and from every release build.
if [[ -z ${CLIPEDGE_UPDATE_FEED:-} && -f tools/publisher.sh ]]; then
    repository_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
    repository_origin=$(git remote get-url origin 2>/dev/null || true)
    if [[ "$PWD" == "$repository_root/projects/clipedge/src" ]] &&
       [[ "$repository_origin" == 'git@github.com:clozach/amaanah.git' || "$repository_origin" == 'https://github.com/clozach/amaanah.git' ]]; then
        /usr/libexec/PlistBuddy -c 'Add :ClipEdgePublisherEnabled bool true' "$bundle_stage/ClipEdge.app/Contents/Info.plist"
        /usr/libexec/PlistBuddy -c "Add :ClipEdgePublisherTool string $PWD/tools/publisher.sh" "$bundle_stage/ClipEdge.app/Contents/Info.plist"
    fi
fi
# Carry the MIT notice with binary distributions as well as source.
if [[ -f LICENSE ]]; then
    mkdir -p "$bundle_stage/ClipEdge.app/Contents/Resources"
    cp LICENSE "$bundle_stage/ClipEdge.app/Contents/Resources/LICENSE"
fi
# A stable certificate keeps macOS's Accessibility grant valid across rebuilds.
# Ad-hoc signatures identify each build by its changing code hash instead.
signing_identity=${CLIPEDGE_SIGN_IDENTITY:-}
if [[ -z "$signing_identity" ]]; then
    signing_identities=()
    while IFS= read -r identity; do signing_identities+=("$identity"); done < <(security find-identity -v -p codesigning | awk '/^[[:space:]]*[0-9]+\)/ {print $2}')
    if [[ ${#signing_identities[@]} == 1 ]]; then signing_identity=${signing_identities[0]}; fi
fi
if [[ -z "$signing_identity" ]]; then
    signing_identity=-
    echo 'WARNING: ad-hoc signing; Accessibility may need re-approval after each build. Set CLIPEDGE_SIGN_IDENTITY to a code-signing certificate.' >&2
fi
# shellcheck disable=SC2086  # CLIPEDGE_SIGN_FLAGS is a deliberate word list (release.sh passes --timestamp).
codesign --force --sign "$signing_identity" ${CLIPEDGE_SIGN_FLAGS:-} --identifier local.codex.ClipEdge "$bundle_stage/ClipEdge.app"
codesign --verify --strict "$bundle_stage/ClipEdge.app"
[[ "$(.build/content-identity "$PWD")" == "$content_fingerprint" ]] || { echo 'Source changed during compilation; build again before installing.' >&2; exit 1; }
if [[ -e .build/ClipEdge.app ]]; then
    # Keep the prior bundle intact for rollback (and any still-running process).
    rm -rf .build/ClipEdge.previous.app
    mv .build/ClipEdge.app .build/ClipEdge.previous.app
fi
mv "$bundle_stage/ClipEdge.app" .build/ClipEdge.app
