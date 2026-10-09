# What's new in ClipEdge

## 2.3.1

- **Starting up no longer freezes on an unreachable file.** A copied file in iCloud or on a disconnected drive used to hold up launch while ClipEdge opened it. File items now show a type icon at once and load their preview in the background; images keep full resolution for search. (Found and fixed with ChatGPT on Mom's Mac.)
- **Publish deliberately from the development copy.** A bright Publish button in the drawer and keyboard window shows when that running build differs from the latest published release. The button prepares a fixed, tested release for review; publishing uploads that same build. It disappears only after the published content is verified to match. While it prepares or publishes, the button fills as each step finishes. This maintainer control does not appear in ordinary installations.
- **A failed release check stays visible.** Offline or failed checks show a neutral retry control. A published match describes the available release, not whether another Mac has installed it yet.

## 2.3

- **Turn the cursor magnets off, all or some.** Settings → *Cursor magnets*: one switch, and while it is on, *On copy*, *From the drawer* and *From the window*. With one off, a copy just joins the history and a pick goes straight onto the clipboard, with nothing following the pointer. Quick Look still opens.
- **An item's info no longer covers it.** Hover a card for 2 seconds and its info (text, facts and keys) opens next to the drawer, where Send to opens, instead of under the pointer.
- **The keyboard comes back to your app.** Closing the Option–Command–\\ window with Esc, Return or Command–C returns the keyboard to the app you were in, so your next keys and your own Command–V land there.
- **Editing the search works as usual:** select all, cut, copy, paste, undo and redo. (In the Option–Command–\\ window, Command–C still picks up the selected item.)
- **Colors show as swatches.** A copied color value (hex, RGB, HSL) shows as a circle of that color; it still pastes as the text you copied.

## 2.1

- **ClipEdge keeps itself up to date.** On first launch it asks once: "Keep ClipEdge up to date automatically?" If you say yes, it looks on GitHub once a day for a newer version, checks that the download is signed by the same developer as the copy you have, and installs it while you are not using ClipEdge. Nothing about you or your clipboard is sent. Your macOS permissions (Accessibility, Input Monitoring) carry over, so there is nothing to approve again. The ClipEdge menu bar icon → **Updates** turns this off, checks now, shows what changed, and goes back to the previous version.
- **Clipboard history by keyboard: Option–Command–\\.** A compact window opens over the app you are in, with the newest item selected. Type to search, press the arrow keys to choose, and Return to paste. Command–1, 2 and 3 show All, Images or Text.
- **It reopens where you left off.** Reopen the window or the drawer within a few minutes of using an item and your search is back, with that item selected. Settings → *Reopen on the last search* sets the minutes or turns it off.
- **Command–F goes to the search** in the drawer and in the history window.
- **Paste as plain text: Control–Command–V**, anywhere. In the history window, Control–Command–Return does the same for the selected item.
- **Send to: Tab.** Open the selected item in an app that can read it, or paste it into another running app.
- **Command-click pastes the item you are holding.** A plain click keeps holding it.
- **Facts on every item:** words and characters for text; pixel size, file size and type for pictures; size, type and full path for files; the site for links.

Moving from 2.0: install 2.1 once (see the README). From then on ClipEdge updates itself.

## 2.0

First public release: the clipboard drawer at the screen edge, with search, All / Images / Text tabs, Quick Look previews and the cursor magnet.
