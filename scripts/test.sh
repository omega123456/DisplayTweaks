#!/bin/bash
# Tests (Tests/DisplayTweaksTests). swift-snapshot-testing imports XCTest, which only Xcode ships,
# so this runs `swift test` with Xcode's toolchain while app builds stay on the Command Line Tools.
# Separate scratch path: modules built by Xcode's Swift can't mix with the CLT build in .build/.
# Extra arguments go to `swift test`, e.g. ./scripts/test.sh --filter MenuBar
# Re-record references: delete the .txt files under Tests/DisplayTweaksTests/__Snapshots__, or SNAPSHOT_TESTING_RECORD=all.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
exec swift test --scratch-path .build/xcode "$@"
