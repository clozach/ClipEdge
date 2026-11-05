# README demo media

`screenshot.png` and `demo.gif` use the same six fictional clipboard entries: an angel-and-devil Halloween shopping note, a shopping-list PDF, a costume photo, a friend's message, an example shopping link, and a Sunday café / mat-class plan. “Maya” is fictional. The `example.com` link is a fictional shop address.

`costume-plan.png` was generated with OpenAI image generation for this demo: a sunlit flat lay of silver angel wings and halo, red devil wings and horns, silver and red boots, and makeup. It depicts no real person and contains no copied shop photography. The text and PDF were authored for the fixture. Their displayed copy dates are fixed to October 17, 2026.

The still is the frame at 0.6 seconds of the final GIF, showing ClipEdge's actual drawer and image Quick Look. Its colors therefore share the GIF's palette. The GIF is a macOS screen recording of the actual native controllers: All / Images / Text / Other are browsed with previews, the drawer slides shut, the history window opens and browses the same copies, Copy closes it, and the drawer opens and closes again. The slides use the app's standard 300 ms motion. There is no recreated app UI, storyboard animation, or interpolated transition.

## Reproduce

Requirements: macOS, Apple Command Line Tools, screen-recording permission for the terminal or agent running the capture, and both `ffmpeg` and `ffprobe` on `PATH` for GIF encoding and recording validation. Use an unlocked display at least 1130 × 830 points. The script refuses a locked display and rejects a recording shorter than the complete demo. Run from the repository root:

```bash
bash tools/readme-capture.sh
```

The script compiles `tools/ReadmeCapture.swift` against the original source files, excluding the application's `main.swift`. It refuses to overlap another Swift compiler. If normal ClipEdge is running, it quits that bundle normally before the fixture starts and reopens the same bundle when capture ends, including failure. Its cleanup stops only its own fixture and screen recorder before reopening the normal app. Do not start another ClipEdge during capture.

On the capture machine, hashes of the saved history, history index and preferences are checked before reopening the normal app. The fixture uses a uniquely named pasteboard, an in-memory history store, nil saved preferences, a private preview directory, and an inert paste environment. It never seeds the general clipboard, loads saved history, posts a paste into another app, fetches shopping links, or edits the normal app's settings. A plain AppKit backdrop covers unrelated windows in the captured region. The displayed PDF path is a fictional `~/Downloads/` path; its actual file lives only in the scratch folder.

The default output is `/tmp/clipedge-readme/`: the raw PNG, raw screen-recorded MOV, encoded PNG and GIF, plus `capture.json` documenting the fixture order and capture region. Inspect both encoded files before copying them into this directory:

```bash
cp /tmp/clipedge-readme/screenshot.png docs/demo/screenshot.png
cp /tmp/clipedge-readme/demo.gif docs/demo/demo.gif
```

The 16.6-second GIF omits the recording's first 1.4 seconds and stops at 18 seconds, retaining the native closing and reopening slides. This trims the recorder lead-in; inspect for unrelated system notifications before publishing. Encoding scales the recorded frames to 1100 pixels wide at 15 fps with a 160-color GIF palette. It preserves the recorded animation. The script extracts the still from the encoded GIF at 0.6 seconds, matching the shipped media. Capture tools are cohesive fixture / recording utilities; they add no production application behavior.
