# ClipEdge build/install contract

When the user says `build <this-repository-url>` on a Mac, complete the local installation using README.md. Do not stop at compilation. Run as the person who will use the app, never as root.

1. Read README.md and inspect the existing app's bundle identifier before replacing anything. This project uses `local.codex.ClipEdge`; a different identifier needs an explicit migration decision. Do not delete preferences or clipboard history.
2. Check macOS and Apple Command Line Tools. If missing, run `xcode-select --install`, let the user complete Apple's installer, then continue. Homebrew, Node, just, an Apple account and Xcode's GUI are not required for installation.
3. Clone into the user's own home directory, or reuse a clean checkout of this exact origin. Preserve local edits; do not reset/clean them. From a standalone checkout run `bash tools/update.sh`. It quits CE, Trashes previous installed/running bundles, pulls fast-forward only, builds, verifies, installs in `~/Applications`, and opens it. Failure restores old bundles using the receipt. Do not empty Trash.
4. Complete the README's first-launch checks. macOS permission dialogs require the user's deliberate approval; do not manufacture grants or disable Gatekeeper/SIP. A locally ad-hoc-signed update may require removing/re-adding ClipEdge in Accessibility/Input Monitoring. Open at Login and Dock pinning are opt-in.
5. Verify the app is running from `~/Applications/ClipEdge.app`, its signature checks, its prior edge/tab position remains, and a synthetic copy/preview/paste works. Do not claim a physical Tahoe check from tests on another macOS version. Report installed source commit, signing mode, rollback receipt and any permission step still owed.

Development: `bash tools/test.sh`; packaging: `bash tools/test-install.sh`; build: `bash tools/build.sh`; install without pulling: `bash tools/install.sh`. Use `--demo` only with the normal app quit; demo uses named clipboard fixtures. Never capture or commit a user's clipboard history. Keep the app identifier and placement key stable for updates. Read Resources/README.md before redistributing artwork.
