#!/bin/bash
# Exercise the real update shell with local Git and fake native app operations.
set -euo pipefail
cd "$(dirname "$0")/.."
fixture=$(mktemp -d "${TMPDIR:-/tmp}/clipedge-update-tests.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/seed/tools" "$fixture/bin"
cp tools/update.sh "$fixture/seed/tools/"
printf '.build/\n' > "$fixture/seed/.gitignore"
cat > "$fixture/seed/tools/build.sh" <<'BUILD'
#!/bin/bash
set -eu
echo build >> "$CE_TEST_LOG"
[[ ${CE_FAIL_BUILD:-0} != 1 ]] || exit 23
mkdir -p .build/ClipEdge.app/Contents/MacOS
touch .build/ClipEdge.app/Contents/MacOS/ClipEdge
BUILD
chmod +x "$fixture/seed/tools/build.sh"
cat > "$fixture/installer" <<'INSTALL'
#!/bin/bash
set -eu
echo "$1" >> "$CE_TEST_LOG"
case "$1" in
prepare) echo fixture > "$2" ;;
finish) [[ -f "$3/Contents/MacOS/ClipEdge" ]] ;;
restore) [[ -f "$2" ]] ;;
esac
INSTALL
chmod +x "$fixture/installer"
cat > "$fixture/bin/xcrun" <<'XCRUN'
#!/bin/bash
set -eu
if [[ "$1" == --find ]]; then echo /usr/bin/swiftc; exit; fi
while [[ $# -gt 0 ]]; do
    if [[ "$1" == -o ]]; then cp "$CE_TEST_INSTALLER" "$2"; exit; fi
    shift
done
exit 1
XCRUN
cat > "$fixture/bin/open" <<'OPEN'
#!/bin/bash
echo open >> "$CE_TEST_LOG"
OPEN
chmod +x "$fixture/bin/"*
git -C "$fixture/seed" init -q -b main
git -C "$fixture/seed" add .
git -C "$fixture/seed" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture
git clone -q --bare "$fixture/seed" "$fixture/origin.git"
git clone -q "$fixture/origin.git" "$fixture/Mom With Spaces"
export CE_TEST_LOG="$fixture/operations" CE_TEST_INSTALLER="$fixture/installer"
export PATH="$fixture/bin:$PATH"
run_update() { (cd "$fixture/Mom With Spaces" && bash tools/update.sh) > "$fixture/output" 2>&1; }
check_log() { [[ $(cat "$CE_TEST_LOG") == "$1" ]] || { cat "$fixture/output" "$CE_TEST_LOG"; exit 1; }; }
run_update || { cat "$fixture/output"; exit 1; }
check_log $'prepare\nbuild\nfinish\nopen'
: > "$CE_TEST_LOG"
printf 'local edit\n' > "$fixture/Mom With Spaces/untracked"
if run_update; then echo 'FAIL: dirty checkout accepted'; exit 1; fi
check_log ''
rm "$fixture/Mom With Spaces/untracked"
export CE_FAIL_BUILD=1
if run_update; then echo 'FAIL: failed build accepted'; exit 1; fi
check_log $'prepare\nbuild\nrestore'
unset CE_FAIL_BUILD
: > "$CE_TEST_LOG"
mv "$fixture/origin.git" "$fixture/origin-unavailable.git"
if run_update; then echo 'FAIL: failed pull accepted'; exit 1; fi
check_log $'prepare\nrestore'
echo 'PASS: update sequence, dirty checkout guard, build-failure rollback, pull-failure rollback (local Git; mocked app operations)'
