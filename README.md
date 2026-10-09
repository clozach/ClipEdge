# ClipEdge

A local clipboard drawer for macOS 14 or newer, including **macOS Tahoe 26**. Keep recent text, images and files beside the screen; search them, preview them, and pick one up for pasting, or press **Option–Command–\\** and choose one by keyboard. The app needs no server or subscription. A released copy can optionally look on GitHub once a day for a newer version (see [Updates](#updates)). An ordinary public source build makes no network connections. The maintainer copy also checks GitHub release status; see [Maintainer publication](#maintainer-publication).

## Install with ChatGPT / Codex

On the Mac that will run ClipEdge, use an assistant with local Terminal access and say:

> build https://github.com/clozach/ClipEdge

Read [AGENTS.md](AGENTS.md) for the agent's installation contract. A web-only chat cannot install software on your Mac. Run everything as the intended user, **without sudo**. This sets up that person's own app, settings and history.

**First prerequisite:** Apple's Command Line Tools. Check `xcrun --find swiftc`; if unavailable, run `xcode-select --install` and finish Apple's installer before continuing. No Homebrew, Node, `just`, paid Apple account or Xcode GUI is required.

Clone `https://github.com/clozach/ClipEdge.git` into a folder under your home directory (for example `~/Developer/ClipEdge`). From its root, install the latest release:

```sh
bash tools/install-release.sh
```

It downloads the release, checks its checksum and signature, moves any previous ClipEdge to the Trash, installs `~/Applications/ClipEdge.app` and opens it; a failure restores the previous app. The release is signed with one certificate and keeps itself up to date, so macOS permissions are approved once (see [Updates](#updates)). If the latest release is not such a copy, the script changes nothing and exits with status 3; build from source instead.

## Build from source

A copy built from the public repository never contacts the network and changes only when you rebuild it. For later updates reuse the same clean checkout, preserving any local edits. From its root:

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

## Updates

**A released copy** (installed by `tools/install-release.sh`, or updated from one) keeps itself up to date:

- On first launch a small window asks once: *Keep ClipEdge up to date automatically?* It does not take the keyboard, so typing elsewhere cannot answer it. The answer is a setting with no expiry: ClipEdge menu bar icon → **Updates** → *Update Automatically* turns it on or off at any time. Until it is answered, nothing is requested from the network.
- With updates on, ClipEdge asks GitHub once a day for the latest release (one request; it carries the ClipEdge version and nothing about the person or the clipboard). A newer release is downloaded, and macOS checks that it is the same app signed by the same developer as the running copy. A download that fails that check, or that is not newer, is discarded and never opened.
- The update installs when ClipEdge is not in use: nothing held, no ClipEdge window open, and the keyboard and mouse still for two minutes. ClipEdge saves the history, swaps itself and reopens. The previous version goes to the Trash.
- Because every release has the same signer, macOS keeps its Accessibility and Input Monitoring approvals across updates.
- **Updates** in the menu also offers *Check for Updates Now*, *What's New* (the release notes) and *Go Back* to the previous version while it is still in the Trash. Going back turns automatic updates off, so the older version stays.

**A copy built from source** has no update feed and never updates itself. An ordinary public source build makes no network requests. Its **Updates** menu says so and links to the release.

## Existing tab location and history

Updates retain **`local.codex.ClipEdge`** as the bundle identifier and **`ClipEdgeTabPlacement`** as the saved preference key. The original supplied app and the imported source use this identity; the original source and current app use the same placement schema (edge, center fraction, length and display ID). Replacing an `.app` does not remove these per-user preferences.

- Settings/tab position: `~/Library/Preferences/local.codex.ClipEdge.plist` (managed by macOS preferences).
- History: `~/Library/Application Support/ClipEdge/History.plist`.
- Missing/rearranged display: the app chooses an available display and clamps the tab to its usable area. Exact screen coordinates can therefore change with display configuration.

Before an update, note the visible tab's edge/location. After it opens, compare. **Do not run `defaults delete`, copy another person's preferences/history, or delete Application Support to troubleshoot installation.** If an older app has a different bundle identifier or schema, stop and inspect its settings before migration; do not promise preservation by name alone. Mom's actual Tahoe device remains a required physical check.

## First launch on this Mac

macOS permissions belong to this user and this app's signature, not to the source repository. A released copy keeps them across its own updates. A copy built without a certificate gets a new signature with every build.

1. In System Settings → Privacy & Security, grant ClipEdge **Accessibility** and **Input Monitoring** when requested for paste detection/delivery. Quit/reopen after changing grants. Permission prompts cannot be approved by a README or copied from another Mac. Moving from a copy built on this Mac to a released copy changes the signature once: remove the old ClipEdge entry (−) in both lists, then approve the new one.
2. If a locally built update stops receiving input, remove/re-add the installed ClipEdge in those permission lists. A stable signing certificate can reduce repeated approvals; `CLIPEDGE_SIGN_IDENTITY` selects a local code-signing identity. The build otherwise selects a sole valid identity, or warns and uses ad-hoc signing.
3. Copy harmless test text. Check history, All/Images/Text search, and **Control–Option–Space** for Quick Look. In the drawer, Space toggles preview and arrows follow the visible tab/search results. While an item follows the pointer, Command-click an empty editable document to paste it there; a plain click keeps holding the item, and Command-click on a link or list row keeps its usual meaning. Accessibility policy tests do not substitute for this physical check. Then press **Option–Command–\\** in any app: the history window opens with the newest item selected. Type to search; the same shortcut or the arrow keys choose; Command–1, 2 and 3 show All, Images or Text. Return pastes into the app you were in, Control–Command–Return pastes plain text, Command–C picks the item up without pasting, Command–O opens it in Preview, Tab offers apps to send the item to (Left Arrow or Escape goes back), Command–Delete twice deletes the item for good, and Shift–Command–Delete twice deletes the whole history. Escape clears the search, then closes the window. **Control–Command–V** pastes the clipboard as plain text with no ClipEdge window open.
4. In either search, type a word, press **Command–A**, then type another: the word is replaced. Command–X cuts the selected search text, Command–V pastes text into the search, Command–Z undoes and Shift–Command–Z redoes. In the drawer's search, Command–C copies the selected text; in the history window, Command–C keeps its clipboard-item pickup action.
5. Confirm the tab remains where it was. Choose **Open at Login** in the ClipEdge menu if wanted. Optional Dock pin: `xcrun swift tools/pin-dock.swift`. The app runs outside Command-Tab; its Dock pin is a launch target.

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

[The latest release](https://github.com/clozach/ClipEdge/releases/latest) is a universal ZIP for Apple Silicon and Intel with a `SHA256SUMS` file. `bash tools/install-release.sh` is the recommended way to install it: it checks the checksum and signature and leaves no quarantine mark for Gatekeeper to object to.

To install a ZIP downloaded in a browser by hand: quit ClipEdge using its menu, move the previous `.app` to Trash, unzip the download, and move `ClipEdge.app` into your own `~/Applications` folder. The release is signed but **not notarized**, so macOS blocks a browser download at first launch; allow it under Privacy & Security → Open Anyway only for a release you trust. Do not disable Gatekeeper/SIP or recursively strip quarantine. Leave Library preferences/history in place; keep the old app in Trash until the new one works.

`bash tools/release.sh` prepares that ZIP and checksum under `.build/releases/`, signed with the maintainer's certificate and a signing timestamp, and carrying the update feed. It refuses to build an unsigned release: such a copy cannot update itself and loses its macOS permissions on every update. [CHANGES.md](CHANGES.md) holds the notes each release publishes; `VERSION` holds the version number.

Releases are built locally and uploaded to GitHub; no paid CI or signing service is required. GitHub Releases has no total release-size or bandwidth quota, and standard public-repository Actions runners are free. Apple Developer ID signing/notarization is a separate Apple Developer Program benefit ($99/year unless already enrolled). This project does not provision a paid service or signing certificate automatically. [GitHub Releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases) · [Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions) · [Apple memberships](https://developer.apple.com/support/compare-memberships/)

## Development

```sh
bash tools/test.sh          # native fixture regression checks
bash tools/test-search-editing.sh # quit ClipEdge first; real panel events, fixture captures, clipboard returned
bash tools/test-install.sh  # isolated install, failure and rollback checks
bash tools/test-update.sh   # local Git + mocked app update/failure checks
bash tools/test-self-update.sh  # a stand-in app updates itself, reopens and goes back (needs a signing certificate)
bash tools/build.sh         # current architecture; macOS 14 deployment target
```

`just build/test/install/run/demo/watch` are optional conveniences. Only the watcher requires Node. Fixture/demo use must begin with normal ClipEdge quit: the app has one global shortcut/preview directory. `--demo` uses a named clipboard and disables cross-app delivery; don't substitute real clipboard contents in tests or screenshots.

`tools/export-source.sh NEW_DESTINATION` copies an allowlist of portable code/tests/tooling for publication. It excludes private development history, evidence, machine-specific capture recipes, build products and the old Finder-icon backup. The public repository is a distribution snapshot exported from the maintainer’s canonical development source. Upstream contributions are reconciled there before the next release; avoid independent, divergent edits.

## Maintainer publication

The canonical development checkout can build a **maintainer copy**. Its drawer and history window show a bright pink **Publish… ⇧⌘P** button when the running app differs from the latest published app. It compares the app’s code, resources and build recipe, so reusing a version number does not hide unpublished work. Ordinary public builds and released copies have no publishing capability.

Clicking Publish (or pressing Shift–Command–P in either view) freezes the matching source, runs the automated regression/install/update checks, and builds a signed universal release once. The review shows the proposed version and release notes. **Cancel** is the default; **Command–Return** explicitly publishes the reviewed candidate. Publication reuses those frozen bytes, checks that the previous public release has not changed, and checks the published result before hiding the button. Preparing and cancelling leaves a candidate available for review. After a restart the helper can reuse it when its content, notes, version and prior-release baseline still match. A failed publication can retry that same candidate.

A gray **Check release** control means the comparison is unavailable, for example while offline. **Rebuild needed** means the editable source no longer matches this running copy: rebuild/install it before preparing a release. Status refreshes on launch, on opening either view (with a one-minute cache), and every five minutes. A hidden control does not prove another Mac has installed the release. Local and release version labels can differ (for example 2.3 and 2.3.1) while the app contents match.

While preparing or publishing, the button fills as the helper finishes each step. The helper appends one JSON line per step to a progress file the app names with `--progress-file`; the pace between lines comes from the step durations of recent runs, kept in `.build/publisher/telemetry.json`. The tooltip names the current step.

A pull request merged on GitHub can leave public `main` ahead of the latest release. Apply the same change to this canonical source and rebuild; preparation and publication accept public commits whose changes the candidate already contains, and stop with the commits named when it does not. The release commit is added on top of public `main`, keeping the contributor's commit.

Local builds, private commits and pushes do not publish. Release notes come from `CHANGES.md`’s `Unreleased` section or the chosen next-version section; the next patch version is selected when necessary. The maintainer helper lives only in the canonical checkout and requires GitHub CLI access, Git and the compatible signing certificate. Public exports exclude the helper.

For command-line use, `bash tools/publisher.sh status --running-fingerprint <installed-content-fingerprint>` checks status; `prepare` with the same argument creates a candidate and returns its review fields. Publication requires the returned candidate ID, content fingerprint, archive SHA-256, complete receipt SHA-256 and explicit `--approve`. The former bare `publish-release.sh --publish` command refuses to rebuild and publish implicitly. No approval means no release.
