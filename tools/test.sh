#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
sources=()
for source in *.swift; do
    [[ "$source" == main.swift ]] || sources+=("$source")
done
xcrun swiftc -swift-version 5 "${sources[@]}" tests/FileInspectionTests.swift -o .build/file-inspection-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon -framework PDFKit
.build/file-inspection-tests
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
xcrun swiftc -swift-version 5 ClipboardEntry.swift ClipboardMetadata.swift ClipboardColor.swift ClipboardIcons.swift ClipboardTileTooltip.swift ClipboardTile.swift ClipboardCanvas.swift ClipboardBrowserView.swift ClipboardRecall.swift tests/BrowserTests.swift -o .build/browser-tests -framework AppKit -framework QuartzCore
.build/browser-tests
xcrun swiftc -swift-version 5 ClipboardShortcut.swift ClipboardShortcutRecorder.swift ClipboardHotKey.swift tests/HotKeyTests.swift -o .build/hotkey-tests -framework AppKit -framework Carbon
.build/hotkey-tests
xcrun swiftc -swift-version 5 ClipboardTabGeometry.swift ClipboardTabView.swift ClipboardGlassView.swift tests/TabShapeTests.swift -o .build/tab-shape-tests -framework AppKit
.build/tab-shape-tests
xcrun swiftc -swift-version 5 ClipboardEntry.swift ClipboardMetadata.swift tests/MetadataTests.swift -o .build/metadata-tests -framework AppKit
.build/metadata-tests
xcrun swiftc -swift-version 5 "${sources[@]}" tests/HistoryTests.swift -o .build/history-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon
.build/history-tests
updater=(InstallSupport.swift UpdateModel.swift UpdateStatus.swift UpdateVerifier.swift UpdateFetcher.swift UpdateInstaller.swift UpdateController.swift)
xcrun swiftc -swift-version 5 "${updater[@]}" tests/UpdateTests.swift -o .build/update-tests -framework AppKit -framework Security
.build/update-tests
xcrun swiftc -swift-version 5 "${updater[@]}" tests/UpdateFileTests.swift -o .build/update-file-tests -framework AppKit -framework Security
.build/update-file-tests > .build/update-file-tests.log || { cat .build/update-file-tests.log; exit 1; }
grep -E '^(Skipped|Update file tests passed)' .build/update-file-tests.log

xcrun swiftc -swift-version 5 "${sources[@]}" tests/ColorTests.swift -o .build/color-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon
.build/color-tests
