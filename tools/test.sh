#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
# A default ClipboardMaterializer empties its root on creation, and without this the
# root is the running app's own preview folder. Every suite gets a private one instead.
preview_root="$(mktemp -d "${TMPDIR:-/tmp}/clipedge-test-previews.XXXXXX")"
trap 'rm -rf "$preview_root"' EXIT
export CLIPEDGE_TEST_PREVIEW_ROOT="$preview_root"
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
xcrun swiftc -swift-version 5 "${sources[@]}" tests/TunerTests.swift -o .build/tuner-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon
.build/tuner-tests
xcrun swiftc -swift-version 5 "${sources[@]}" tests/SettingsWindowTests.swift -o .build/settings-window-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon
.build/settings-window-tests
xcrun swiftc -swift-version 5 "${sources[@]}" tests/SizesTests.swift -o .build/sizes-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon
.build/sizes-tests
xcrun swiftc -swift-version 5 "${sources[@]}" tests/StorageTests.swift -o .build/storage-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon
.build/storage-tests
xcrun swiftc -swift-version 5 "${sources[@]}" tests/DrawerControlsTests.swift -o .build/drawer-controls-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon
.build/drawer-controls-tests
xcrun swiftc -swift-version 5 "${sources[@]}" tests/KeyboardHandBackTests.swift -o .build/keyboard-handback-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon
.build/keyboard-handback-tests
xcrun swiftc -swift-version 5 "${sources[@]}" tests/DrawerSettingsTests.swift -o .build/drawer-settings-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon
.build/drawer-settings-tests
xcrun swiftc -swift-version 5 "${sources[@]}" tests/DrawerPreviewTests.swift -o .build/drawer-preview-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon
.build/drawer-preview-tests
xcrun swiftc -swift-version 5 "${sources[@]}" tests/TabNavigationTests.swift -o .build/tab-navigation-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon
.build/tab-navigation-tests
xcrun swiftc -swift-version 5 PasteMonitor.swift tests/PasteDeliveryTests.swift -o .build/paste-tests -framework AppKit
.build/paste-tests
xcrun swiftc -swift-version 5 CommandClickPaste.swift ClickPasteTarget.swift tests/ClickPasteTests.swift -o .build/click-tests -framework AppKit
.build/click-tests
xcrun swiftc -swift-version 5 ClipboardEntry.swift ClipboardAppData.swift ClipboardMetadata.swift ClipboardSummary.swift ClipboardFigmaCopy.swift ClipboardHTMLText.swift ClipboardWebCopies.swift ClipboardColor.swift ClipboardIcons.swift ClipboardSurface.swift ClipboardSizes.swift ClipboardStorageBudget.swift ClipboardStorageBar.swift ClipboardStorageWarning.swift ClipboardTileTooltip.swift ClipboardTypedPreview.swift ClipboardTile.swift ClipboardChord.swift ClipboardKeymap.swift ClipboardKeyCap.swift ClipboardCanvas.swift ClipboardBrowserTab.swift ClipboardBrowserParts.swift ClipboardBrowserList.swift ClipboardBrowserView.swift ClipboardPreviewBrief.swift ClipboardPreviewBriefDocument.swift ClipboardMarking.swift tests/BrowserTests.swift -o .build/browser-tests -framework AppKit -framework QuartzCore
.build/browser-tests
xcrun swiftc -swift-version 5 ClipboardChord.swift ClipboardShortcut.swift ClipboardShortcutRecorder.swift ClipboardHotKey.swift tests/HotKeyTests.swift -o .build/hotkey-tests -framework AppKit -framework Carbon
.build/hotkey-tests
xcrun swiftc -swift-version 5 ClipboardTabGeometry.swift ClipboardTabView.swift ClipboardGlassView.swift ClipboardSurface.swift ClipboardSizes.swift ClipboardDrawerEdgeGrip.swift tests/TabShapeTests.swift -o .build/tab-shape-tests -framework AppKit
.build/tab-shape-tests
xcrun swiftc -swift-version 5 ClipboardEntry.swift ClipboardAppData.swift ClipboardMetadata.swift ClipboardSummary.swift ClipboardFigmaCopy.swift ClipboardHTMLText.swift ClipboardWebCopies.swift tests/MetadataTests.swift -o .build/metadata-tests -framework AppKit
.build/metadata-tests
xcrun swiftc -swift-version 5 "${sources[@]}" tests/HistoryTests.swift -o .build/history-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon
.build/history-tests
xcrun swiftc -swift-version 5 "${sources[@]}" tests/MarkingTests.swift -o .build/marking-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon
.build/marking-tests
xcrun swiftc -swift-version 5 "${sources[@]}" tests/MultiSelectTests.swift -o .build/multi-select-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon
.build/multi-select-tests
xcrun swiftc -swift-version 5 "${sources[@]}" tests/RawDataTests.swift -o .build/raw-data-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon -framework PDFKit
.build/raw-data-tests
xcrun swiftc -swift-version 5 "${sources[@]}" tests/FlipTests.swift -o .build/flip-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon -framework PDFKit
.build/flip-tests
updater=(InstallSupport.swift UpdateModel.swift UpdateStatus.swift UpdateVerifier.swift UpdateFetcher.swift UpdateInstaller.swift UpdateController.swift)
xcrun swiftc -swift-version 5 "${updater[@]}" tests/UpdateTests.swift -o .build/update-tests -framework AppKit -framework Security
.build/update-tests
xcrun swiftc -swift-version 5 "${updater[@]}" tests/UpdateFileTests.swift -o .build/update-file-tests -framework AppKit -framework Security
.build/update-file-tests > .build/update-file-tests.log || { cat .build/update-file-tests.log; exit 1; }
grep -E '^(Skipped|Update file tests passed)' .build/update-file-tests.log

xcrun swiftc -swift-version 5 "${sources[@]}" tests/ColorTests.swift -o .build/color-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon
.build/color-tests
xcrun swiftc -swift-version 5 "${sources[@]}" tests/AppearanceTests.swift -o .build/appearance-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon
.build/appearance-tests
xcrun swiftc -swift-version 5 "${sources[@]}" tests/WebCopyTests.swift -o .build/web-copy-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon -framework PDFKit
.build/web-copy-tests
xcrun swiftc -swift-version 5 "${sources[@]}" tests/AppDataTests.swift -o .build/app-data-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon -framework PDFKit
.build/app-data-tests
xcrun swiftc -swift-version 5 "${sources[@]}" tests/TypedPreviewTests.swift -o .build/typed-preview-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon -framework PDFKit
.build/typed-preview-tests
xcrun swiftc -swift-version 5 "${sources[@]}" tests/PreviewBriefTests.swift -o .build/preview-brief-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon
.build/preview-brief-tests
xcrun swiftc -swift-version 5 "${sources[@]}" tests/SampleHistoryTests.swift -o .build/sample-history-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon -framework PDFKit
.build/sample-history-tests

xcrun swiftc -swift-version 5 PublishModel.swift PublishLimits.swift PublishProtocol.swift PublishProgress.swift PublishProcess.swift PublishReview.swift PublishController.swift tests/PublishTests.swift -o .build/publish-tests -framework AppKit
.build/publish-tests
xcrun swiftc -swift-version 5 PublishModel.swift PublishLimits.swift PublishProtocol.swift PublishProgress.swift PublishProcess.swift PublishReview.swift PublishController.swift tests/PublishProgressTests.swift -o .build/publish-progress-tests -framework AppKit
.build/publish-progress-tests
xcrun swiftc -swift-version 5 "${sources[@]}" tests/PublishControlTests.swift -o .build/publish-control-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon
.build/publish-control-tests

xcrun swiftc -swift-version 5 "${sources[@]}" tests/PrepareIsolationTests.swift -o .build/prepare-isolation-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon
.build/prepare-isolation-tests

xcrun swiftc -swift-version 5 "${sources[@]}" tests/AccessKeysTests.swift -o .build/access-keys-tests -framework AppKit -framework Vision -framework QuickLookUI -framework Carbon -framework PDFKit
.build/access-keys-tests
