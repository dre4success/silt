#!/bin/bash
# Command Line Tools ship swift-testing's macro plugin in a subfolder the compiler doesn't search
# by default (Xcode passes it for you), so point at it explicitly.
set -euo pipefail
cd "$(dirname "$0")"
PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
