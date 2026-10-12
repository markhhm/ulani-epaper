#!/usr/bin/env bash
# Run `swift test` for apple/UlaniKit. With only the Command Line Tools installed
# (no Xcode), Swift Testing is not on the default search path; add it.
# Usage: apple/scripts/swift-test.sh [swift test options...]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
args=(--package-path "$here/../UlaniKit")
if [[ "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* ]]; then
  F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
  L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
  args+=(-Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F"
         -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L")
fi
exec swift test "${args[@]}" "$@"
