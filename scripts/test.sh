#!/bin/zsh
set -eu
cd "${0:A:h:h}"
TEST_DIR=$(/usr/bin/mktemp -d /tmp/mac-power-modes-tests.XXXXXX)
trap '/bin/rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -swift-version 5 -framework AppKit Sources/PowerSettings.swift Sources/Authorization.swift Tests/main.swift -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
