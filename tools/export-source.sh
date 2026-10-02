#!/bin/bash
# Export only portable source, not vault history, evidence, backups or user data.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# == 1 && ! -e "$1" ]] || { echo 'Usage: export-source.sh NEW_DESTINATION' >&2; exit 1; }
destination=$1
mkdir -p "$destination/tools" "$destination/tests" "$destination/Resources"
cp ./*.swift README.md AGENTS.md Justfile .gitignore "$destination/"
cp tests/*.swift "$destination/tests/"
for file in build.sh install.sh update.sh InstallSupport.swift Installer.swift test.sh test-install.sh test-update.sh InstallTests.swift export-source.sh release.sh watch.mjs pin-dock.swift; do
    cp "tools/$file" "$destination/tools/"
done
cp Resources/AppIcon.icns Resources/README.md "$destination/Resources/"
[[ ! -f LICENSE ]] || cp LICENSE "$destination/"
[[ ! -f NOTICE ]] || cp NOTICE "$destination/"
# Export does not create a remote or upload files.
echo "Portable MIT source prepared at $destination."
