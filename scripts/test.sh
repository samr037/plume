#!/bin/sh
# Tests unitaires. Avec les Command Line Tools seules, le plugin des macros Swift Testing doit être indiqué explicitement.
# Build hors de ~/Claude (sync → "build.db disk I/O error").
cd "$(dirname "$0")/.." || exit 1
PLUGIN=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if [ -d "$PLUGIN" ] && ! xcode-select -p 2>/dev/null | grep -q Xcode; then
  exec swift test --scratch-path "${WL_BUILD:-/tmp/wl-build}" -Xswiftc -plugin-path -Xswiftc "$PLUGIN" "$@"
fi
exec swift test --scratch-path "${WL_BUILD:-/tmp/wl-build}" "$@"
