#!/bin/bash
# Export only portable source, not vault history, evidence, backups or user data.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# == 1 && ! -e "$1" ]] || { echo 'Usage: export-source.sh NEW_DESTINATION' >&2; exit 1; }
destination=$1
mkdir -p "$destination/tools" "$destination/tests" "$destination/Resources"
mkdir -p "$destination/tools/publisher"
cp tools/publisher/Identity.swift tools/publisher/IdentityMain.swift "$destination/tools/publisher/"
cp ./*.swift README.md AGENTS.md CHANGES.md VERSION Justfile .gitignore "$destination/"
cp tests/*.swift "$destination/tests/"
for file in build.sh install.sh install-release.sh update.sh Installer.swift test.sh test-search-editing.sh SearchEditingCapture.swift test-install.sh test-update.sh test-self-update.sh InstallTests.swift UpdateFixture.swift export-source.sh release.sh watch.mjs pin-dock.swift; do
    cp "tools/$file" "$destination/tools/"
done
cp Resources/AppIcon.icns Resources/README.md "$destination/Resources/"
[[ ! -f LICENSE ]] || cp LICENSE "$destination/"
[[ ! -f NOTICE ]] || cp NOTICE "$destination/"
# Export does not create a remote or upload files.
echo "Portable MIT source prepared at $destination."
