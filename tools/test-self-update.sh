#!/bin/bash
# End-to-end check of the updater: a running app downloads a newer copy, checks its signature,
# replaces itself, reopens, and goes back. Uses a stand-in app with its own bundle identifier
# (never ClipEdge itself) in a temporary folder. The real Trash is used, so each run leaves one
# small "ClipEdgeUpdateFixture" item there. Optional argument: a file to copy the log to.
set -euo pipefail
cd "$(dirname "$0")/.."
identity=${CLIPEDGE_SIGN_IDENTITY:-}
if [[ -z $identity ]]; then
    identity=$(security find-identity -v -p codesigning | awk '/^[[:space:]]*[0-9]+\)/ {print $2; exit}')
fi
if [[ -z $identity || $identity == - ]]; then
    echo 'Skipped: this check needs a code-signing certificate (two copies must share a signer).'
    exit 0
fi
root=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/clipedge-self-update.XXXXXX")" && pwd -P)
trap 'rm -rf "$root"' EXIT
id=local.codex.ClipEdge.updatefixture
name=ClipEdgeUpdateFixture.app
xcrun swiftc -swift-version 5 InstallSupport.swift UpdateModel.swift UpdateStatus.swift UpdateVerifier.swift UpdateFetcher.swift \
    UpdateInstaller.swift UpdateController.swift UpdateLive.swift tools/UpdateFixture.swift \
    -o "$root/fixture" -framework AppKit -framework Security

# make_app FOLDER VERSION SIGNER SCENARIO_ROOT
make_app() {
    local app="$1/$name"
    mkdir -p "$app/Contents/MacOS"
    cp "$root/fixture" "$app/Contents/MacOS/ClipEdge"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$id</string>
<key>CFBundleName</key><string>ClipEdgeUpdateFixture</string>
<key>CFBundleExecutable</key><string>ClipEdge</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$2</string>
<key>CFBundleVersion</key><string>$2</string>
<key>LSUIElement</key><true/>
<key>ClipEdgeUpdateFeed</key><string>file://$4/feed/latest.json</string>
</dict></plist>
PLIST
    codesign --force --sign "$3" --identifier "$id" "$app" 2>/dev/null
}

# scenario NAME INSTALLED_SIGNER RELEASE_SIGNER RELEASE_VERSION -> leaves $here/log.txt
scenario() {
    here="$root/$1"
    mkdir -p "$here/Applications" "$here/release" "$here/feed"
    make_app "$here/Applications" 1.0 "$2" "$here"
    make_app "$here/release" "$4" "$3" "$here"
    ditto -c -k --sequesterRsrc --keepParent "$here/release/$name" "$here/feed/ClipEdge-fixture.zip"
    local size; size=$(stat -f %z "$here/feed/ClipEdge-fixture.zip")
    printf '{"tag_name":"v%s","html_url":"https://example.com/notes","assets":[{"name":"ClipEdge-fixture.zip","browser_download_url":"file://%s/feed/ClipEdge-fixture.zip","size":%s}]}' "$4" "$here" "$size" > "$here/feed/latest.json"
    open -g "$here/Applications/$name"
    for _ in $(seq 1 300); do
        if grep -q 'done$' "$here/log.txt" 2>/dev/null; then return 0; fi
        sleep 0.2
    done
    echo "FAIL ($1): the fixture did not finish. Log:" >&2; cat "$here/log.txt" >&2 || true
    exit 1
}
expect() { grep -q -- "$2" "$here/log.txt" || { echo "FAIL ($1): expected '$2'. Log:" >&2; cat "$here/log.txt" >&2; exit 1; }; }
installed() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$here/Applications/$name/Contents/Info.plist"; }
checks=0
pass() { checks=$((checks + 1)); }

scenario update "$identity" "$identity" 2.0
expect update 'launch 1.0 .*available'; pass
expect update '^ready 2.0$'; pass
expect update '^launch 2.0 '; pass
expect update 'updated from 1.0 to 2.0; way back: true'; pass
expect update 'back on 1.0; automatic updates off; done'; pass
[[ $(grep -c '^launch ' "$here/log.txt") == 3 ]] || { echo 'FAIL (update): expected three launches' >&2; cat "$here/log.txt" >&2; exit 1; }; pass
[[ $(installed) == 1.0 ]] || { echo 'FAIL (update): Go Back did not leave 1.0 installed' >&2; exit 1; }; pass
codesign --verify --strict "$here/Applications/$name"; pass
update_log=$(cat "$here/log.txt")

scenario other-signer "$identity" - 2.0
expect other-signer 'refused: The download was not installed: it is not signed by the same developer as this copy'; pass
[[ $(installed) == 1.0 && $(grep -c '^launch ' "$here/log.txt") == 1 ]] || { echo 'FAIL (other-signer): the unsigned release was installed' >&2; exit 1; }; pass
other_log=$(cat "$here/log.txt")

scenario older "$identity" "$identity" 0.9
expect older 'newest; done'; pass
[[ $(installed) == 1.0 ]] || { echo 'FAIL (older): an older release replaced a newer copy' >&2; exit 1; }; pass

scenario local-build - "$identity" 2.0
expect local-build 'blocked(.*unsigned)'; pass
expect local-build 'no check ran; done'; pass
[[ $(installed) == 1.0 ]] || { echo 'FAIL (local-build): a locally built copy replaced itself' >&2; exit 1; }; pass

if [[ $# == 1 ]]; then
    { echo "# update, then go back"; echo "$update_log"; echo; echo "# release from another signer"; echo "$other_log"; } | sed "s|$root|<temporary folder>|g" > "$1"
fi
echo "Self-update check passed: $checks checks (update and reopen, go back, other signer refused, older release ignored, local build never updates)."
