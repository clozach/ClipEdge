#!/bin/bash
# Build and record the original native views using only fictional clipboard data.
set -euo pipefail
cd "$(dirname "$0")/.."
photo=${1:-docs/demo/costume-plan.png}
scratch=${2:-/tmp/clipedge-readme}
mkdir -p "$scratch"
check_display() {
    local sessions
    sessions=$(/usr/sbin/ioreg -n Root -d1 -a | /usr/bin/plutil -extract IOConsoleUsers json -o - -)
    if [[ "$sessions" == *'"CGSSessionScreenIsLocked":true'* ]]; then
        echo 'The Mac display is locked. Unlock it, then rerun the capture.' >&2
        return 1
    fi
}
for dependency in ffmpeg ffprobe; do
    command -v "$dependency" >/dev/null || { echo "Required command missing: $dependency" >&2; exit 1; }
done
check_display
[[ -f "$photo" ]] || { echo "Missing fixture photo: $photo" >&2; exit 1; }
# Compile once, outside the app bundle. Serialize with any other Swift builds.
if pgrep -x swiftc >/dev/null || pgrep -x swift-frontend >/dev/null; then
    echo 'Another Swift compiler is running. Retry when it finishes.' >&2
    exit 1
fi
sources=()
for source in *.swift; do [[ "$source" == main.swift ]] || sources+=("$source"); done
nice -n 19 xcrun swiftc -swift-version 5 "${sources[@]}" tools/ReadmeCapture.swift \
    -o "$scratch/readme-capture" -framework AppKit -framework QuickLookUI \
    -framework Vision -framework Carbon -framework QuickLookThumbnailing -framework AVFoundation
# Never run the fixture alongside normal ClipEdge. Ask the running bundle to quit
# normally, then reopen that same bundle on completion or an interrupted capture.
app_path=''
fixture_pid=''
restore() {
    # Stop only processes spawned by this script, before reopening normal ClipEdge.
    if [[ -n "$fixture_pid" ]] && kill -0 "$fixture_pid" 2>/dev/null; then
        while IFS= read -r child; do
            if [[ -n "$child" ]]; then
                kill -TERM "$child" 2>/dev/null || true
                for attempt in {1..30}; do
                    kill -0 "$child" 2>/dev/null || break
                    sleep 0.1
                done
                # The exact child was created by our fixture, never another recorder.
                if [[ $(ps -p "$child" -o ppid= | tr -d ' ') == "$fixture_pid" ]]; then
                    kill -KILL "$child" 2>/dev/null || true
                fi
            fi
        done < <(pgrep -P "$fixture_pid" -x screencapture || true)
        kill -TERM "$fixture_pid" 2>/dev/null || true
        wait "$fixture_pid" 2>/dev/null || true
    fi
    [[ -z "$app_path" ]] || /usr/bin/open "$app_path"
}
trap restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if pgrep -x ClipEdge >/dev/null; then
    pid=$(pgrep -x ClipEdge)
    [[ "$pid" != *$'\n'* ]] || { echo 'Several ClipEdge processes are running; stop before capture.' >&2; exit 1; }
    executable=$(ps -p "$pid" -o comm=)
    candidate=${executable%/Contents/MacOS/ClipEdge}
    [[ "$candidate" == *.app ]] || { echo 'Cannot identify the running ClipEdge bundle.' >&2; exit 1; }
    app_path=$candidate
    /usr/bin/osascript -e 'on run argv' -e 'tell application (item 1 of argv) to quit' -e 'end run' "$app_path"
    for attempt in {1..40}; do pgrep -x ClipEdge >/dev/null || break; sleep 0.1; done
    pgrep -x ClipEdge >/dev/null && { echo 'ClipEdge has not quit; capture cancelled.' >&2; exit 1; }
fi
check_display
state_files=()
for state in \
    "$HOME/Library/Application Support/ClipEdge/History.plist" \
    "$HOME/Library/Application Support/ClipEdge/History.store/Index.plist" \
    "$HOME/Library/Preferences/local.codex.ClipEdge.plist"; do
    [[ ! -f "$state" ]] || state_files+=("$state")
done
if (( ${#state_files[@]} )); then shasum "${state_files[@]}" > "$scratch/state-before.sha"; fi
"$scratch/readme-capture" "$photo" "$scratch" &
fixture_pid=$!
wait "$fixture_pid"
fixture_pid=''
if (( ${#state_files[@]} )); then shasum -c "$scratch/state-before.sha"; fi
if [[ "${CLIPEDGE_README_STILL_ONLY:-0}" == 1 ]]; then
    echo "Review $scratch/screenshot-raw.png."
    exit 0
fi
duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$scratch/demo-raw.mov")
awk -v duration="$duration" 'BEGIN { exit !(duration >= 18) }' || {
    echo "Screen recording stopped early ($duration seconds). Retry capture; do not publish it." >&2
    exit 1
}
# Keep WindowServer motion. Scale/re-encode only; no storyboard or tweened frames.
ffmpeg -hide_banner -loglevel error -y -ss 1.4 -i "$scratch/demo-raw.mov" \
    -t 16.6 -vf 'fps=15,scale=1100:-2:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=160:stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=3' \
    -loop 0 "$scratch/demo.gif"
ffmpeg -hide_banner -loglevel error -y -ss 0.6 -i "$scratch/demo.gif" \
    -frames:v 1 "$scratch/screenshot.png"
echo "Review $scratch/screenshot.png and $scratch/demo.gif before copying into docs/demo/."
