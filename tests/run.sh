#!/bin/sh
# Suites A and B (fast, sandboxed, no UI). Suite C (tests/e2e_claude.py) drives a real `claude`
# session and uses tokens; Suite D (tests/screen_smoke.sh) takes screenshots. Run those by hand.
set -e
cd "$(dirname "$0")/.."
python3 tests/helper_tests.py
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
swiftc -swift-version 5 -parse-as-library -D SNAPSHOT -target "$(uname -m)-apple-macos14.0" \
  src/Shared.swift src/Theme.swift src/Matrix.swift src/Export.swift src/Update.swift src/Welcome.swift src/App.swift \
  tests/StoreTests.swift -o "$T/storetests"
"$T/storetests"
