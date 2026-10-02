# ClipEdge

A local clipboard drawer for macOS 14 or newer, including **macOS Tahoe 26**. Keep recent text, images and files beside the screen; search them, preview them, and pick one up for pasting. No server, subscription or network service is needed by the app.

## Build and install with ChatGPT / Codex

On the Mac that will run ClipEdge, use an assistant with local Terminal access and say:

> build https://github.com/clozach/ClipEdge

Read [AGENTS.md](AGENTS.md) for the agent's installation contract. A web-only chat cannot install software on your Mac. Run everything as the intended user, **without sudo**. This sets up that person's own app, settings and history.

**First prerequisite:** Apple's Command Line Tools. Check `xcrun --find swiftc`; if unavailable, run `xcode-select --install` and finish Apple's installer before continuing. No Homebrew, Node, `just`, paid Apple account or Xcode GUI is required. Build on the destination Mac to match its Apple Silicon or Intel processor.

Clone `https://github.com/clozach/ClipEdge.git` into a folder under your home directory (for example `~/Developer/ClipEdge`). For later updates reuse that clean checkout, preserving any local edits. From its root:

```sh
bash tools/update.sh
```

The update command:

1. Checks for a standalone, clean Git checkout with an upstream before touching the app.
2. Asks running ClipEdge instances to quit and save. It stops if a save dialog prevents quitting; it does not force-kill them.
3. Moves previous ClipEdge bundles in `~/Applications`, `/Applications`, and any running ClipEdge location to the Mac's Trash. Unrecognized bundles or insufficient permissions stop the update. A protected `/Applications` copy may need to be moved to Trash in Finder first.
4. Runs `git pull --ff-only`, compiles and signs, verifies the signature, and installs in `~/Applications/ClipEdge.app`.
5. Opens the new app. If pulling, building or installing fails, it restores the old bundles from Trash. It prints the rollback receipt and command. Do not empty Trash until the update is accepted.

For source downloaded as a ZIP, or a development checkout nested inside another repo, skip Git updating:

```sh
bash tools/build.sh
bash tools/install.sh
open "$HOME/Applications/ClipEdge.app"
```

That path builds before quitting/replacing the old app. It uses the same Trash/rollback transaction. Both paths install the app only; neither deletes or imports a user's clipboard/settings.

## Existing tab location and history

Updates retain **`local.codex.ClipEdge`** as the bundle identifier and **`ClipEdgeTabPlacement`** as the saved preference key. The original supplied app and the imported source use this identity; the original source and current app use the same placement schema (edge, center fraction, length and display ID). Replacing an `.app` does not remove these per-user preferences.

- Settings/tab position: `~/Library/Preferences/local.codex.ClipEdge.plist` (managed by macOS preferences).
- History: `~/Library/Application Support/ClipEdge/History.plist`.
- Missing/rearranged display: the app chooses an available display and clamps the tab to its usable area. Exact screen coordinates can therefore change with display configuration.

Before an update, note the visible tab's edge/location. After it opens, compare. **Do not run `defaults delete`, copy another person's preferences/history, or delete Application Support to troubleshoot installation.** If an older app has a different bundle identifier or schema, stop and inspect its settings before migration; do not promise preservation by name alone. Mom's actual Tahoe device remains a required physical check.

## First launch on this Mac

The app can run with a local ad-hoc signature; macOS permissions belong to this user and this app identity, not to the source repository.

1. In System Settings → Privacy & Security, grant ClipEdge **Accessibility** and **Input Monitoring** when requested for paste detection/delivery. Quit/reopen after changing grants. Permission prompts cannot be approved by a README or copied from another Mac.
2. If an ad-hoc update stops receiving input, remove/re-add the installed ClipEdge in those permission lists. A stable signing certificate can reduce repeated approvals; `CLIPEDGE_SIGN_IDENTITY` selects a local code-signing identity. The build otherwise selects a sole valid identity, or warns and uses ad-hoc signing.
3. Copy harmless test text. Check history, All/Images/Text search, and **Control–Option–Space** for Quick Look. In the drawer, Space toggles preview and arrows follow the visible tab/search results. Test ordinary click-to-paste in an empty editable document; Shift-click keeps holding the item. Accessibility policy tests do not substitute for this physical check.
4. Confirm the tab remains where it was. Choose **Open at Login** in the ClipEdge menu if wanted. Optional Dock pin: `xcrun swift tools/pin-dock.swift`. The app runs outside Command-Tab; its Dock pin is a launch target.

Verify package integrity with:

```sh
codesign --verify --strict "$HOME/Applications/ClipEdge.app"
```

A valid signature is not a claim of Apple notarization or granted permissions. Report the installed source commit (`git rev-parse --short HEAD`), signing mode and any remaining first-launch steps.

## Undo an update

The command printed at installation uses a private `.build/install-…json` or `.build/update-…json` receipt:

```sh
.build/installer restore "/full/path/to/the/printed/receipt.json"
```

It quits ClipEdge, moves the new app to Trash and restores prior bundles to their original locations without overwriting another file. Then open the restored app. Keep the receipt and Trash contents until satisfied. If the command is interrupted or a restore destination is occupied, use the receipt's `original`/`trashed` paths to finish the restore in Finder. Old app restoration does not rewind subsequent history changes.

## Binary downloads and publication

Created by **Chris Lozac'h** (<clozach@gmail.com>), with direction through prompting, a personal knowledge vault and development tooling, assisted by ChatGPT.app and Claude.app. Code and the bundled icon are released under the [MIT License](LICENSE). See [icon provenance](Resources/README.md).

[Download the latest release](https://github.com/clozach/ClipEdge/releases/latest). The universal ZIP runs on Apple Silicon and Intel; `SHA256SUMS` checks its downloaded bytes. Local source builds remain the recommended route for the one-prompt installation.

For a binary install, quit ClipEdge using its menu, move the previous `.app` to Trash, unzip the download, and move `ClipEdge.app` into your own `~/Applications` folder. Open that copy and complete the first-launch checks above. Leave Library preferences/history in place; keep the old app in Trash until the new one works. Restore it from Trash if needed.

`bash tools/release.sh` prepares a universal Apple Silicon + Intel ZIP and SHA-256 checksum under `.build/releases/`. This free build is **ad-hoc signed, not notarized**. A downloaded binary may be blocked by Gatekeeper. Prefer the local source-build path above, or follow macOS's explicit Privacy & Security → Open Anyway flow only for a release you trust. Do not disable Gatekeeper/SIP or recursively strip quarantine.

Releases are built locally and uploaded to GitHub; no paid CI or signing service is required. GitHub Releases has no total release-size or bandwidth quota, and standard public-repository Actions runners are free. Apple Developer ID signing/notarization is a separate Apple Developer Program benefit ($99/year unless already enrolled). This project does not provision a paid service or signing certificate automatically. [GitHub Releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases) · [Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions) · [Apple memberships](https://developer.apple.com/support/compare-memberships/)

## Development

```sh
bash tools/test.sh          # native fixture regression checks
bash tools/test-install.sh  # isolated install, failure and rollback checks
bash tools/test-update.sh   # local Git + mocked app update/failure checks
bash tools/build.sh         # current architecture; macOS 14 deployment target
```

`just build/test/install/run/demo/watch` are optional conveniences. Only the watcher requires Node. Fixture/demo use must begin with normal ClipEdge quit: the app has one global shortcut/preview directory. `--demo` uses a named clipboard and disables cross-app delivery; don't substitute real clipboard contents in tests or screenshots.

`tools/export-source.sh NEW_DESTINATION` copies an allowlist of portable code/tests/tooling for publication. It excludes private development history, evidence, machine-specific capture recipes, build products and the old Finder-icon backup. The public repository is a distribution snapshot exported from the maintainer’s canonical development source. Upstream contributions are reconciled there before the next release; avoid independent, divergent edits.
