# README demo media

The still and reel share six fictional clipboard entries from October 17, 2026. Maya and a friend are planning angel-and-devil costumes for a rooftop party. They've copied a shopping note, a PDF checklist, a photo, a message and a shop link. A Sunday plan for coffee, flowers and a mat class has slipped into the history too.

The accessory photo in `costume-plan.png` was generated with OpenAI image generation for this demo. The text and PDF were written for it. The shop link uses `example.com`.

In `demo.gif`, follow the pointer through Images, Text and Other in the drawer. Space previews the costume photo. The on-screen shortcuts then show how to close the drawer, open Clipboard History and copy the photo. A click on the edge tab brings the drawer back.

macOS records the native windows and their drawer animation. The recording fixture draws the macOS arrow in a transparent overlay. It moves to each control and shows a press ring when the fixture activates it. For tabs, the fixture checks which segment the pointer hits and sends the control's action. The edge tab receives mouse-down and mouse-up events. Keyboard cues show the chord just before the action and stay visible through the response. The fixture routes the two global shortcuts to their app actions locally. Space and Copy use the app's key handlers.

The same sequence runs twice, first as a rehearsal and then as the recording. Each action checks its result. Copy must close the history window and place the original PNG bytes on the fixture's named pasteboard.

## Regenerate the reel

Use an unlocked Mac with at least 1000 × 740 points of usable display area, Apple Command Line Tools and both `ffmpeg` and `ffprobe` on `PATH`. Grant screen-recording permission to the terminal or agent running the capture. Run this from the repository root.

```bash
bash tools/readme-capture.sh
```

This compiles the capture helpers against the original source files, excluding the application's `main.swift`, at low priority and without overlapping another Swift compiler. It quits normal ClipEdge, rehearses, records, checks the results and reopens the same normal bundle. A process-bounded display-awake assertion runs during each fixture; lock settings are preserved. The Swift and shell cleanup stop only their own recorder/fixture before the backdrop leaves or the normal app returns. Short recordings and failed input assertions are rejected.

The fixture uses a uniquely named pasteboard, in-memory history, nil saved preferences, a private preview directory and an inert paste environment. It never seeds the general clipboard, loads saved history, posts a paste into another app, fetches shopping links or edits the normal app's settings. Saved history, index and preference hashes are checked after the fixture. The displayed PDF path is fictional; its real file lives only in the scratch folder.

The raw MOV, GIF, rehearsal results and recording timeline are written to `/tmp/clipedge-readme/`. Watch one complete loop at the README's 720-pixel width. Check that the arrow reaches its control, each cue precedes the response, and Copy closes history before the edge click reopens the drawer. Then copy the reviewed reel.

```bash
cp /tmp/clipedge-readme/demo.gif docs/demo/demo.gif
```

For a rehearsal without a take, use `CLIPEDGE_README_REHEARSE_ONLY=1 bash tools/readme-capture.sh`.

## Preserve the approved still

`screenshot.png` is the approved All + Quick Look view showing the six story clues. It is the frame at 0.6 seconds of the original reel and shares that GIF's palette. The new reel command preserves this file.

The original capture tools and recipe are in [revision `243887c`](https://github.com/clozach/ClipEdge/commit/243887c). To reproduce that version, use a separate checkout.

```bash
git worktree add --detach /tmp/clipedge-original-still 243887c
cd /tmp/clipedge-original-still
bash tools/readme-capture.sh
```

That revision records the original 16.6-second reel and extracts its frame at 0.6 seconds.
