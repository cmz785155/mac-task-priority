#!/bin/zsh
set -eu
cd "${0:A:h:h}"
TEST_DIR=$(/usr/bin/mktemp -d /tmp/mac-power-modes-tests.XXXXXX)
trap '/bin/rm -rf "$TEST_DIR"' EXIT
xcrun clang -O2 -Wall -Wextra Sources/priority-helper.c -o "$TEST_DIR/priority-helper"
xcrun clang -O2 -Wall -Wextra -c Sources/ProcessProbe.c -o "$TEST_DIR/probe.o"
xcrun swiftc -import-objc-header Sources/ProcessProbe.h "$TEST_DIR/probe.o" -swift-version 5 -framework AppKit Sources/Authorization.swift Sources/TaskPriority.swift Tests/main.swift -o "$TEST_DIR/tests"
"$TEST_DIR/tests" "$TEST_DIR/priority-helper"
