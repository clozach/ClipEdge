#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc tools/InstallSupport.swift tools/InstallTests.swift -o .build/install-tests
.build/install-tests "$@"
xcrun swiftc tools/InstallSupport.swift tools/Installer.swift -o .build/installer -framework AppKit
