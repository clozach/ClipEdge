#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
sources=()
for source in *.swift; do
    [[ "$source" == main.swift ]] || sources+=("$source")
done
xcrun swiftc -swift-version 5 "${sources[@]}" tests/CoreTests.swift -o .build/core-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon -framework PDFKit
.build/core-tests
xcrun swiftc -swift-version 5 "${sources[@]}" tests/PickupTests.swift -o .build/pickup-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon
.build/pickup-tests
xcrun swiftc -swift-version 5 "${sources[@]}" tests/RevealTests.swift -o .build/reveal-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon
.build/reveal-tests
xcrun swiftc -swift-version 5 "${sources[@]}" tests/DrawerPreviewTests.swift -o .build/drawer-preview-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon
.build/drawer-preview-tests
xcrun swiftc -swift-version 5 "${sources[@]}" tests/TabNavigationTests.swift -o .build/tab-navigation-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon
.build/tab-navigation-tests
xcrun swiftc -swift-version 5 PasteMonitor.swift tests/PasteDeliveryTests.swift -o .build/paste-tests -framework AppKit
.build/paste-tests
xcrun swiftc -swift-version 5 CommandClickPaste.swift ClickPasteTarget.swift tests/ClickPasteTests.swift -o .build/click-tests -framework AppKit
.build/click-tests
xcrun swiftc -swift-version 5 ClipboardEntry.swift ClipboardIcons.swift ClipboardTileTooltip.swift ClipboardTile.swift ClipboardCanvas.swift ClipboardBrowserView.swift tests/BrowserTests.swift -o .build/browser-tests -framework AppKit -framework QuartzCore
.build/browser-tests
xcrun swiftc -swift-version 5 ClipboardShortcut.swift ClipboardShortcutRecorder.swift ClipboardHotKey.swift tests/HotKeyTests.swift -o .build/hotkey-tests -framework AppKit -framework Carbon
.build/hotkey-tests
xcrun swiftc -swift-version 5 ClipboardTabGeometry.swift ClipboardTabView.swift ClipboardGlassView.swift tests/TabShapeTests.swift -o .build/tab-shape-tests -framework AppKit
.build/tab-shape-tests
